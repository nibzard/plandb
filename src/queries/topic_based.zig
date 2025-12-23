//! Topic-based query interface with scope expressions
//!
//! Implements structured queries against topic cartridges with:
//! - Term combination logic (AND/OR/NOT)
//! - Scope expressions (entity type filters, time ranges, confidence thresholds)
//! - Result ranking and relevance scoring

const std = @import("std");
const mem = std.mem;

const EntityId = @import("../cartridges/structured_memory.zig").EntityId;
const Entity = @import("../cartridges/structured_memory.zig").Entity;
const EntityType = @import("../cartridges/structured_memory.zig").EntityType;

pub const TopicQuery = struct {
    /// Query terms to search for
    terms: []const []const u8,
    /// Boolean operators between terms
    operators: []const BooleanOp,
    /// Scope filters
    filters: []const ScopeFilter,
    /// Maximum results to return
    limit: usize = 100,
    /// Minimum confidence threshold
    min_confidence: f32 = 0.0,

    pub const BooleanOp = enum {
        @"and",
        @"or",
        @"not",
    };

    pub fn deinit(self: TopicQuery, allocator: std.mem.Allocator) void {
        for (self.terms) |term| allocator.free(term);
        allocator.free(self.terms);
        allocator.free(self.operators);
        for (self.filters) |*f| f.deinit(allocator);
        allocator.free(self.filters);
    }
};

pub const ScopeFilter = struct {
    /// Filter type
    filter_type: FilterType,
    /// String value for entity_type, wildcard patterns
    string_value: ?[]const u8 = null,
    /// Numeric value for confidence, txn_id
    numeric_value: ?f64 = null,
    /// Range for numeric comparisons
    range: ?ValueRange = null,

    pub const FilterType = enum {
        entity_type,
        confidence,
        after_txn,
        before_txn,
        time_range,
        wildcard,
    };

    pub const ValueRange = struct {
        min: f64,
        max: f64,
    };

    pub fn deinit(self: *ScopeFilter, allocator: std.mem.Allocator) void {
        if (self.string_value) |v| allocator.free(v);
    }

    pub fn matches(self: ScopeFilter, entity_id: EntityId, entity: *const Entity) bool {
        return switch (self.filter_type) {
            .entity_type => self.matchEntityType(entity.type),
            .confidence => self.matchConfidence(entity),
            .after_txn => self.matchAfterTxn(entity),
            .before_txn => self.matchBeforeTxn(entity),
            .time_range => self.matchTimeRange(entity),
            .wildcard => self.matchWildcard(entity_id),
        };
    }

    fn matchEntityType(self: ScopeFilter, entity_type: EntityType) bool {
        const expected = self.string_value orelse return false;
        const type_name = @tagName(entity_type);
        return mem.eql(u8, type_name, expected);
    }

    fn matchConfidence(self: ScopeFilter, entity: *const Entity) bool {
        const threshold = self.numeric_value orelse return false;
        return entity.confidence >= @as(f32, @floatCast(threshold));
    }

    fn matchAfterTxn(self: ScopeFilter, entity: *const Entity) bool {
        const min_txn = self.numeric_value orelse return false;
        return entity.created_at >= @as(u64, @intFromFloat(@floor(min_txn)));
    }

    fn matchBeforeTxn(self: ScopeFilter, entity: *const Entity) bool {
        const max_txn = self.numeric_value orelse return false;
        return entity.created_at <= @as(u64, @intFromFloat(@floor(max_txn)));
    }

    fn matchTimeRange(self: ScopeFilter, entity: *const Entity) bool {
        const range = self.range orelse return false;
        const txn = @as(f64, @floatFromInt(entity.created_at));
        return txn >= range.min and txn <= range.max;
    }

    fn matchWildcard(self: ScopeFilter, entity_id: EntityId) bool {
        const pattern = self.string_value orelse return false;
        return wildcardMatch(pattern, entity_id.local_id);
    }
};

pub const TopicResult = struct {
    entity_id: EntityId,
    score: f32,
    matched_terms: [][]const u8,
    topic_path: ?[]const u8 = null,

    pub fn deinit(self: *TopicResult, allocator: std.mem.Allocator) void {
        for (self.matched_terms) |t| allocator.free(t);
        allocator.free(self.matched_terms);
        allocator.free(self.entity_id.namespace);
        allocator.free(self.entity_id.local_id);
        if (self.topic_path) |p| allocator.free(p);
    }
};

/// Interface for topic query execution
/// Concrete implementations would integrate with TopicCartridge and EntityIndexCartridge
pub const QueryEngine = struct {
    allocator: std.mem.Allocator,
    /// In real implementation, these would be references to cartridges
    topic_cartridge_opaque: *const anyopaque,
    entity_cartridge_opaque: *const anyopaque,

    const Self = @This();

    pub fn init(
        allocator: std.mem.Allocator,
        topic_cartridge: *const anyopaque,
        entity_cartridge: *const anyopaque
    ) QueryEngine {
        return QueryEngine{
            .allocator = allocator,
            .topic_cartridge_opaque = topic_cartridge,
            .entity_cartridge_opaque = entity_cartridge,
        };
    }

    /// Execute a topic query with scope filters
    pub fn execute(self: *Self, query: TopicQuery) ![]TopicResult {
        _ = self;
        _ = query;
        // Placeholder implementation - real implementation would:
        // 1. Get entity IDs matching each term from TopicCartridge
        // 2. Apply boolean operators (AND/OR/NOT)
        // 3. Apply scope filters (entity type, time range, confidence)
        // 4. Calculate TF-IDF scores
        // 5. Sort by score and apply limit
        return error.NotImplemented;
    }
};

pub const ScopeParser = struct {
    allocator: std.mem.Allocator,
    input: []const u8,
    pos: usize = 0,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, input: []const u8) ScopeParser {
        return ScopeParser{
            .allocator = allocator,
            .input = input,
        };
    }

    pub fn parse(self: *Self) !TopicQuery {
        var terms = std.array_list.Managed([]const u8).init(self.allocator);
        var operators = std.array_list.Managed(TopicQuery.BooleanOp).init(self.allocator);
        var filters = std.array_list.Managed(ScopeFilter).init(self.allocator);

        errdefer {
            for (terms.items) |t| self.allocator.free(t);
            terms.deinit();
            operators.deinit();
            for (filters.items) |*f| f.deinit(self.allocator);
            filters.deinit();
        }

        while (self.pos < self.input.len) {
            self.skipWhitespace();

            if (self.pos >= self.input.len) break;

            // Check for filter expression (key:value or key:"value")
            if (self.tryParseFilter(&filters)) {
                self.skipWhitespace();
                // Look for AND between filters
                if (self.tryConsume("AND")) {
                    continue;
                }
                continue;
            }

            // Parse term
            const term = try self.parseTerm();
            try terms.append(term);

            self.skipWhitespace();

            // Look for operator
            if (self.tryConsume("AND")) {
                try operators.append(.@"and");
            } else if (self.tryConsume("OR")) {
                try operators.append(.@"or");
            } else if (self.tryConsume("NOT")) {
                try operators.append(.@"not");
            }
        }

        // If no operators specified, default to AND
        if (operators.items.len == 0 and terms.items.len > 1) {
            const default_and = try self.allocator.alloc(TopicQuery.BooleanOp, terms.items.len - 1);
            @memset(default_and, .@"and");
            return TopicQuery{
                .terms = try terms.toOwnedSlice(),
                .operators = default_and,
                .filters = try filters.toOwnedSlice(),
                .limit = 100,
                .min_confidence = 0.0,
            };
        }

        return TopicQuery{
            .terms = try terms.toOwnedSlice(),
            .operators = try operators.toOwnedSlice(),
            .filters = try filters.toOwnedSlice(),
            .limit = 100,
            .min_confidence = 0.0,
        };
    }

    fn tryParseFilter(self: *Self, filters: *std.ArrayList(ScopeFilter)) !bool {
        const start = self.pos;

        // Try to parse key:value format
        const key = self.parseIdentifier() catch return false;
        defer self.allocator.free(key);

        if (self.pos >= self.input.len or self.input[self.pos] != ':') {
            self.pos = start;
            return false;
        }
        self.pos += 1; // consume ':'

        self.skipWhitespace();

        const value = try self.parseValue();
        errdefer self.allocator.free(value);

        // Create filter based on key
        const filter_type = filterTypeFromString(key) orelse {
            self.allocator.free(value);
            self.pos = start;
            return false;
        };

        const filter = try self.createFilter(filter_type, value);
        try filters.append(filter);

        return true;
    }

    fn createFilter(self: *Self, filter_type: ScopeFilter.FilterType, value: []const u8) !ScopeFilter {
        return switch (filter_type) {
            .entity_type => ScopeFilter{
                .filter_type = .entity_type,
                .string_value = try self.allocator.dupe(u8, value),
                .numeric_value = null,
                .range = null,
            },
            .confidence => ScopeFilter{
                .filter_type = .confidence,
                .string_value = null,
                .numeric_value = try std.fmt.parseFloat(f64, value),
                .range = null,
            },
            .after_txn => ScopeFilter{
                .filter_type = .after_txn,
                .string_value = null,
                .numeric_value = try std.fmt.parseFloat(f64, value),
                .range = null,
            },
            .before_txn => ScopeFilter{
                .filter_type = .before_txn,
                .string_value = null,
                .numeric_value = try std.fmt.parseFloat(f64, value),
                .range = null,
            },
            .wildcard => ScopeFilter{
                .filter_type = .wildcard,
                .string_value = try self.allocator.dupe(u8, value),
                .numeric_value = null,
                .range = null,
            },
            .time_range => blk: {
                // Parse "min,max" format
                var iter = mem.splitScalar(u8, value, ',');
                const min_str = iter.next() orelse return error.InvalidRangeFormat;
                const max_str = iter.next() orelse return error.InvalidRangeFormat;
                break :blk ScopeFilter{
                    .filter_type = .time_range,
                    .string_value = null,
                    .numeric_value = null,
                    .range = .{
                        .min = try std.fmt.parseFloat(f64, min_str),
                        .max = try std.fmt.parseFloat(f64, max_str),
                    },
                };
            },
        };
    }

    fn parseTerm(self: *Self) ![]const u8 {
        self.skipWhitespace();

        // Check for quoted string
        if (self.pos < self.input.len and self.input[self.pos] == '"') {
            return self.parseQuotedString();
        }

        // Parse unquoted term until whitespace or operator
        const start = self.pos;
        while (self.pos < self.input.len) {
            const c = self.input[self.pos];
            if (c == ' ' or c == '\t' or c == '\n') break;
            self.pos += 1;
        }

        if (self.pos == start) return error.EmptyTerm;

        return try self.allocator.dupe(u8, self.input[start..self.pos]);
    }

    fn parseQuotedString(self: *Self) ![]const u8 {
        if (self.pos >= self.input.len or self.input[self.pos] != '"') return error.ExpectedQuote;
        self.pos += 1; // consume opening quote

        const start = self.pos;
        while (self.pos < self.input.len) {
            if (self.input[self.pos] == '"') {
                if (self.pos > 0 and self.input[self.pos - 1] != '\\') break;
            }
            self.pos += 1;
        }

        if (self.pos >= self.input.len) return error.UnterminatedString;

        const result = try self.allocator.dupe(u8, self.input[start..self.pos]);
        self.pos += 1; // consume closing quote
        return result;
    }

    fn parseValue(self: *Self) ![]const u8 {
        self.skipWhitespace();

        // Check for quoted string
        if (self.pos < self.input.len and self.input[self.pos] == '"') {
            return self.parseQuotedString();
        }

        // Parse unquoted value until whitespace or operator
        const start = self.pos;
        while (self.pos < self.input.len) {
            const c = self.input[self.pos];
            if (c == ' ' or c == '\t' or c == '\n' or c == ':') break;
            self.pos += 1;
        }

        if (self.pos == start) return error.EmptyValue;

        return try self.allocator.dupe(u8, self.input[start..self.pos]);
    }

    fn parseIdentifier(self: *Self) ![]const u8 {
        self.skipWhitespace();

        const start = self.pos;
        while (self.pos < self.input.len) {
            const c = self.input[self.pos];
            // Allow alphanumeric, underscore, dot, hyphen
            if (std.ascii.isAlNum(c) or c == '_' or c == '.' or c == '-') {
                self.pos += 1;
            } else {
                break;
            }
        }

        if (self.pos == start) return error.EmptyIdentifier;

        return try self.allocator.dupe(u8, self.input[start..self.pos]);
    }

    fn skipWhitespace(self: *Self) void {
        while (self.pos < self.input.len) {
            const c = self.input[self.pos];
            if (c == ' ' or c == '\t' or c == '\n' or c == '\r') {
                self.pos += 1;
            } else {
                break;
            }
        }
    }

    fn tryConsume(self: *Self, str: []const u8) bool {
        self.skipWhitespace();

        if (self.pos + str.len > self.input.len) return false;

        if (mem.eqlIgnoreCase(u8, self.input[self.pos..][0..str.len], str)) {
            self.pos += str.len;
            return true;
        }

        return false;
    }
};

fn filterTypeFromString(str: []const u8) ?ScopeFilter.FilterType {
    if (mem.eql(u8, str, "entity_type")) return .entity_type;
    if (mem.eql(u8, str, "type")) return .entity_type;
    if (mem.eql(u8, str, "confidence")) return .confidence;
    if (mem.eql(u8, str, "after")) return .after_txn;
    if (mem.eql(u8, str, "after_txn")) return .after_txn;
    if (mem.eql(u8, str, "before")) return .before_txn;
    if (mem.eql(u8, str, "before_txn")) return .before_txn;
    if (mem.eql(u8, str, "time_range")) return .time_range;
    if (mem.eql(u8, str, "wildcard")) return .wildcard;
    return null;
}

fn wildcardMatch(pattern: []const u8, text: []const u8) bool {
    var p_idx: usize = 0;
    var t_idx: usize = 0;
    var p_star: usize = 0;
    var t_star: usize = 0;

    while (t_idx < text.len) {
        if (p_idx < pattern.len and pattern[p_idx] == '*') {
            p_star = p_idx;
            t_star = t_idx;
            p_idx += 1;
        } else if (p_idx < pattern.len and (pattern[p_idx] == text[t_idx] or pattern[p_idx] == '?')) {
            p_idx += 1;
            t_idx += 1;
        } else if (p_star < pattern.len) {
            p_idx = p_star + 1;
            t_star += 1;
            t_idx = t_star;
        } else {
            return false;
        }
    }

    while (p_idx < pattern.len and pattern[p_idx] == '*') {
        p_idx += 1;
    }

    return p_idx == pattern.len;
}

fn sortResults(items: []TopicResult) void {
    std.sort.insertion(TopicResult, items, {}, struct {
        fn lessThan(_: void, a: TopicResult, b: TopicResult) bool {
            return a.score > b.score;
        }
    }.lessThan);
}

// ==================== Tests ====================//

test "ScopeParser.parse simple term" {
    const input = "database";
    var parser = ScopeParser.init(std.testing.allocator, input);
    const query = try parser.parse();
    defer query.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), query.terms.len);
    try std.testing.expectEqualStrings("database", query.terms[0]);
}

test "ScopeParser.parse multiple terms AND" {
    const input = "database performance btree";
    var parser = ScopeParser.init(std.testing.allocator, input);
    const query = try parser.parse();
    defer query.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 3), query.terms.len);
    try std.testing.expectEqual(@as(usize, 2), query.operators.len);
    try std.testing.expectEqual(TopicQuery.BooleanOp.@"and", query.operators[0]);
}

test "ScopeParser.parse with explicit AND" {
    const input = "database AND performance";
    var parser = ScopeParser.init(std.testing.allocator, input);
    const query = try parser.parse();
    defer query.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), query.terms.len);
    try std.testing.expectEqual(TopicQuery.BooleanOp.@"and", query.operators[0]);
}

test "ScopeParser.parse with entity_type filter" {
    const input = "database entity_type:file";
    var parser = ScopeParser.init(std.testing.allocator, input);
    const query = try parser.parse();
    defer query.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), query.terms.len);
    try std.testing.expectEqual(@as(usize, 1), query.filters.len);
    try std.testing.expectEqual(ScopeFilter.FilterType.entity_type, query.filters[0].filter_type);
    try std.testing.expectEqualStrings("file", query.filters[0].string_value.?);
}

test "ScopeParser.parse with confidence filter" {
    const input = "database confidence:0.8";
    var parser = ScopeParser.init(std.testing.allocator, input);
    const query = try parser.parse();
    defer query.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), query.filters.len);
    try std.testing.expectEqual(ScopeFilter.FilterType.confidence, query.filters[0].filter_type);
    try std.testing.expectApproxEqAbs(@as(f64, 0.8), query.filters[0].numeric_value.?, 0.001);
}

test "ScopeParser.parse with after_txn filter" {
    const input = "database after:100";
    var parser = ScopeParser.init(std.testing.allocator, input);
    const query = try parser.parse();
    defer query.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), query.filters.len);
    try std.testing.expectEqual(ScopeFilter.FilterType.after_txn, query.filters[0].filter_type);
}

test "ScopeParser.parse with wildcard filter" {
    const input = "database wildcard:*.zig";
    var parser = ScopeParser.init(std.testing.allocator, input);
    const query = try parser.parse();
    defer query.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), query.filters.len);
    try std.testing.expectEqual(ScopeFilter.FilterType.wildcard, query.filters[0].filter_type);
    try std.testing.expectEqualStrings("*.zig", query.filters[0].string_value.?);
}

test "ScopeParser.parse quoted string" {
    const input = "\"database performance\"";
    var parser = ScopeParser.init(std.testing.allocator, input);
    const query = try parser.parse();
    defer query.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), query.terms.len);
    try std.testing.expectEqualStrings("database performance", query.terms[0]);
}

test "ScopeFilter.matchEntityType" {
    var entity = try Entity.init(
        std.testing.allocator,
        .{ .namespace = "file", .local_id = "test.zig" },
        .file,
        "test",
        100
    );
    defer entity.deinit(std.testing.allocator);

    const filter = ScopeFilter{
        .filter_type = .entity_type,
        .string_value = "file",
        .numeric_value = null,
        .range = null,
    };

    const entity_id = EntityId{ .namespace = "file", .local_id = "test.zig" };
    try std.testing.expect(filter.matches(entity_id, &entity));

    const filter_wrong = ScopeFilter{
        .filter_type = .entity_type,
        .string_value = "person",
        .numeric_value = null,
        .range = null,
    };
    try std.testing.expect(!filter_wrong.matches(entity_id, &entity));
}

test "ScopeFilter.matchConfidence" {
    var entity = try Entity.init(
        std.testing.allocator,
        .{ .namespace = "file", .local_id = "test.zig" },
        .file,
        "test",
        100
    );
    defer entity.deinit(std.testing.allocator);
    entity.confidence = 0.85;

    const filter = ScopeFilter{
        .filter_type = .confidence,
        .string_value = null,
        .numeric_value = 0.8,
        .range = null,
    };

    const entity_id = EntityId{ .namespace = "file", .local_id = "test.zig" };
    try std.testing.expect(filter.matches(entity_id, &entity));

    const filter_high = ScopeFilter{
        .filter_type = .confidence,
        .string_value = null,
        .numeric_value = 0.9,
        .range = null,
    };
    try std.testing.expect(!filter_high.matches(entity_id, &entity));
}

test "ScopeFilter.matchAfterTxn" {
    var entity = try Entity.init(
        std.testing.allocator,
        .{ .namespace = "file", .local_id = "test.zig" },
        .file,
        "test",
        100
    );
    defer entity.deinit(std.testing.allocator);

    const filter = ScopeFilter{
        .filter_type = .after_txn,
        .string_value = null,
        .numeric_value = 50,
        .range = null,
    };

    const entity_id = EntityId{ .namespace = "file", .local_id = "test.zig" };
    try std.testing.expect(filter.matches(entity_id, &entity));

    const filter_future = ScopeFilter{
        .filter_type = .after_txn,
        .string_value = null,
        .numeric_value = 150,
        .range = null,
    };
    try std.testing.expect(!filter_future.matches(entity_id, &entity));
}

test "ScopeFilter.matchBeforeTxn" {
    var entity = try Entity.init(
        std.testing.allocator,
        .{ .namespace = "file", .local_id = "test.zig" },
        .file,
        "test",
        100
    );
    defer entity.deinit(std.testing.allocator);

    const filter = ScopeFilter{
        .filter_type = .before_txn,
        .string_value = null,
        .numeric_value = 150,
        .range = null,
    };

    const entity_id = EntityId{ .namespace = "file", .local_id = "test.zig" };
    try std.testing.expect(filter.matches(entity_id, &entity));

    const filter_past = ScopeFilter{
        .filter_type = .before_txn,
        .string_value = null,
        .numeric_value = 50,
        .range = null,
    };
    try std.testing.expect(!filter_past.matches(entity_id, &entity));
}

test "wildcardMatch exact match" {
    try std.testing.expect(wildcardMatch("test.zig", "test.zig"));
}

test "wildcardMatch prefix wildcard" {
    try std.testing.expect(wildcardMatch("*.zig", "test.zig"));
    try std.testing.expect(wildcardMatch("*.zig", "main.zig"));
    try std.testing.expect(!wildcardMatch("*.zig", "test.txt"));
}

test "wildcardMatch suffix wildcard" {
    try std.testing.expect(wildcardMatch("test.*", "test.zig"));
    try std.testing.expect(wildcardMatch("test.*", "test.txt"));
    try std.testing.expect(!wildcardMatch("test.*", "main.zig"));
}

test "wildcardMatch question mark" {
    try std.testing.expect(wildcardMatch("test.???", "test.zig"));
    try std.testing.expect(wildcardMatch("test.???", "test.txt"));
    try std.testing.expect(!wildcardMatch("test.???", "test.html"));
}

test "wildcardMatch multiple wildcards" {
    try std.testing.expect(wildcardMatch("*.*", "test.zig"));
    try std.testing.expect(wildcardMatch("*.*", "main.txt"));
    try std.testing.expect(!wildcardMatch("*.*", "no_extension"));
}

test "ScopeFilter.matchWildcard" {
    var entity = try Entity.init(
        std.testing.allocator,
        .{ .namespace = "file", .local_id = "test.zig" },
        .file,
        "test",
        100
    );
    defer entity.deinit(std.testing.allocator);

    const filter = ScopeFilter{
        .filter_type = .wildcard,
        .string_value = "*.zig",
        .numeric_value = null,
        .range = null,
    };

    const entity_id = EntityId{ .namespace = "file", .local_id = "test.zig" };
    try std.testing.expect(filter.matches(entity_id, &entity));

    const filter_txt = ScopeFilter{
        .filter_type = .wildcard,
        .string_value = "*.txt",
        .numeric_value = null,
        .range = null,
    };
    try std.testing.expect(!filter_txt.matches(entity_id, &entity));
}
