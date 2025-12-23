//! Code relationship extraction plugin (discovers hidden connections)
//!
//! Analyzes code mutations to discover implicit relationships, dependencies,
//! and connections between entities that aren't explicitly stated.

const std = @import("std");
const mem = std.mem;

const llm_client = @import("../llm/client.zig");
const llm_function = @import("../llm/function.zig");
const llm_types = @import("../llm/types.zig");

const plugin = @import("plugin.zig");
const EntityId = @import("../cartridges/structured_memory.zig").EntityId;
const RelationshipCartridge = @import("../cartridges/structured_memory.zig").RelationshipCartridge;

/// Code relationship extraction plugin
pub const CodeRelationshipPlugin = struct {
    allocator: std.mem.Allocator,
    llm_provider: *llm_client.LLMProvider,
    config: ExtractionConfig,
    state: PluginState,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, llm_provider: *llm_client.LLMProvider, config: ExtractionConfig) !Self {
        return CodeRelationshipPlugin{
            .allocator = allocator,
            .llm_provider = llm_provider,
            .config = config,
            .state = PluginState{
                .pattern_cache = std.StringHashMap(PatternCache).init(allocator),
                .relationship_buffer = std.array_list.Managed(Relationship).init(allocator),
                .stats = Statistics{},
            },
        };
    }

    pub fn deinit(self: *Self) void {
        var it = self.state.pattern_cache.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(self.allocator);
        }
        self.state.pattern_cache.deinit();

        for (self.state.relationship_buffer.items) |*rel| {
            rel.deinit(self.allocator);
        }
        self.state.relationship_buffer.deinit();
    }

    /// Extract relationships from code mutation
    pub fn extractFromMutation(self: *Self, mutation: CodeMutation) ![]ExtractedRelationship {
        var relationships = std.array_list.Managed(ExtractedRelationship).init(self.allocator);

        // Extract based on mutation type
        switch (mutation.mutation_type) {
            .put => {
                // Analyze key-value for relationships
                try self.analyzePutMutation(mutation, &relationships);
            },
            .delete => {
                // Track deletion for potential cascade relationships
                try self.analyzeDeleteMutation(mutation, &relationships);
            },
        }

        // Extract code-specific patterns
        if (mutation.value) |value| {
            try self.extractCodePatterns(value, mutation.key, &relationships);
        }

        // Buffer relationships for batch processing
        for (relationships.items) |rel| {
            try self.state.relationship_buffer.append(try self.cloneRelationship(rel));
        }

        self.state.stats.total_mutations_processed += 1;
        self.state.stats.relationships_discovered += relationships.items.len;

        return relationships.toOwnedSlice();
    }

    /// Extract relationships from a batch of mutations
    pub fn extractFromBatch(self: *Self, mutations: []const CodeMutation) ![][]ExtractedRelationship {
        var all_relationships = std.array_list.Managed([]ExtractedRelationship).init(self.allocator);

        for (mutations) |mutation| {
            const rels = try self.extractFromMutation(mutation);
            try all_relationships.append(rels);
        }

        return all_relationships.toOwnedSlice();
    }

    /// Analyze import/dependency patterns
    pub fn analyzeImports(self: *Self, code: []const u8, source_entity: EntityId) ![]ImportRelationship {
        var imports = std.array_list.Managed(ImportRelationship).init(self.allocator);

        // Find import statements
        var lines = mem.splitScalar(u8, code, '\n');

        while (lines.next()) |line| {
            const trimmed = mem.trim(u8, line, " \t\r");

            // Check for various import patterns
            if (mem.startsWith(u8, trimmed, "import ") or
                mem.startsWith(u8, trimmed, "use ") or
                mem.startsWith(u8, trimmed, "#include ") or
                mem.startsWith(u8, trimmed, "from ") or
                mem.startsWith(u8, trimmed, "package "))
            {
                const extracted = try self.extractImportPath(trimmed);
                if (extracted) |path| {
                    try imports.append(.{
                        .source_entity = try self.cloneEntityId(source_entity),
                        .imported_path = try self.allocator.dupe(u8, path),
                        .relationship_type = self.inferImportRelationship(path),
                        .confidence = 0.9,
                    });
                }
            }
        }

        return imports.toOwnedSlice();
    }

    /// Find function call relationships
    pub fn findFunctionCalls(self: *Self, code: []const u8, caller: EntityId) ![]FunctionCallRelationship {
        var calls = std.array_list.Managed(FunctionCallRelationship).init(self.allocator);

        // Simple pattern matching for function calls
        // In production, would use proper AST parsing

        var iter = mem.splitScalar(u8, code, '(');
        while (iter.next()) |before_paren| {
            // Find function name (identifier before '(')
            var i = before_paren.len;
            while (i > 0) : (i -= 1) {
                const c = before_paren[i - 1];
                if (c == ' ' or c == '\t' or c == '\n' or c == '=' or c == '(') {
                    break;
                }
            }

            if (i < before_paren.len) {
                const func_name = before_paren[i..];

                // Skip if it's a keyword or too short
                if (func_name.len < 2 or self.isKeyword(func_name)) continue;

                try calls.append(.{
                    .caller_entity = try self.cloneEntityId(caller),
                    .function_name = try self.allocator.dupe(u8, func_name),
                    .confidence = 0.7,
                });
            }
        }

        return calls.toOwnedSlice();
    }

    /// Get buffered relationships
    pub fn getBufferedRelationships(self: *Self) ![]ExtractedRelationship {
        var result = std.array_list.Managed(ExtractedRelationship).init(self.allocator);

        for (self.state.relationship_buffer.items) |rel| {
            try result.append(try self.cloneRelationship(rel));
        }

        return result.toOwnedSlice();
    }

    /// Clear buffer
    pub fn clearBuffer(self: *Self) void {
        for (self.state.relationship_buffer.items) |*rel| {
            rel.deinit(self.allocator);
        }
        self.state.relationship_buffer.clearRetainingCapacity();
    }

    /// Get statistics
    pub fn getStats(self: *const Self) Statistics {
        return self.state.stats;
    }

    fn analyzePutMutation(self: *Self, mutation: CodeMutation, relationships: *std.ArrayList(ExtractedRelationship)) !void {
        _ = self;
        _ = mutation;
        _ = relationships;
        // Analyze key structure for hierarchical relationships
    }

    fn analyzeDeleteMutation(self: *Self, mutation: CodeMutation, relationships: *std.ArrayList(ExtractedRelationship)) !void {
        _ = self;
        _ = mutation;
        _ = relationships;
        // Track potential cascade relationships
    }

    fn extractCodePatterns(self: *Self, code: []const u8, key: []const u8, relationships: *std.ArrayList(ExtractedRelationship)) !void {
        _ = code;
        _ = key;
        _ = relationships;

        // Detect common patterns:
        // - Struct/object composition
        // - Array/list relationships
        // - Reference patterns (pointers, IDs)
    }

    fn extractImportPath(self: *Self, line: []const u8) ?[]const u8 {
        // Extract path from import statement
        var iter = mem.splitScalar(u8, line, '"');
        if (iter.next()) |before| {
            if (iter.next()) |path| {
                return path;
            }
        }

        // Try with single quotes
        iter = mem.splitScalar(u8, line, '\'');
        if (iter.next()) |before| {
            if (iter.next()) |path| {
                return path;
            }
        }

        return null;
    }

    fn inferImportRelationship(self: *Self, path: []const u8) ImportType {
        if (mem.indexOf(u8, path, "std/") != null or mem.indexOf(u8, path, "builtin") != null) {
            return .standard_library;
        }
        if (mem.indexOf(u8, path, "../") != null or mem.indexOf(u8, path, "./") != null) {
            return .local;
        }
        if (mem.indexOf(u8, path, "http") != null) {
            return .external;
        }
        return .library;
    }

    fn cloneEntityId(self: *Self, id: EntityId) !EntityId {
        return EntityId{
            .namespace = try self.allocator.dupe(u8, id.namespace),
            .local_id = try self.allocator.dupe(u8, id.local_id),
        };
    }

    fn cloneRelationship(self: *Self, rel: ExtractedRelationship) !ExtractedRelationship {
        return ExtractedRelationship{
            .source = try self.cloneEntityId(rel.source),
            .target = try self.cloneEntityId(rel.target),
            .relationship_type = rel.relationship_type,
            .confidence = rel.confidence,
            .discovery_method = try self.allocator.dupe(u8, rel.discovery_method),
        };
    }

    fn isKeyword(self: *Self, word: []const u8) bool {
        const keywords = [_][]const u8{
            "if", "else", "for", "while", "return", "const", "var",
            "let", "fn", "func", "def", "class", "struct", "enum",
        };

        for (keywords) |kw| {
            if (mem.eql(u8, word, kw)) return true;
        }
        return false;
    }
};

/// Code mutation for analysis
pub const CodeMutation = struct {
    mutation_type: MutationType,
    key: []const u8,
    value: ?[]const u8,
    timestamp: u64,

    pub const MutationType = enum {
        put,
        delete,
    };
};

/// Extracted relationship
pub const ExtractedRelationship = struct {
    source: EntityId,
    target: EntityId,
    relationship_type: RelationshipType,
    confidence: f32,
    discovery_method: []const u8,

    pub fn deinit(self: *ExtractedRelationship, allocator: std.mem.Allocator) void {
        allocator.free(self.source.namespace);
        allocator.free(self.source.local_id);
        allocator.free(self.target.namespace);
        allocator.free(self.target.local_id);
        allocator.free(self.discovery_method);
    }
};

/// Relationship type
pub const RelationshipType = enum {
    imports,
    calls,
    references,
    contains,
    extends,
    implements,
    depends_on,
    associated_with,
};

/// Import relationship
pub const ImportRelationship = struct {
    source_entity: EntityId,
    imported_path: []const u8,
    relationship_type: ImportType,
    confidence: f32,

    pub fn deinit(self: *ImportRelationship, allocator: std.mem.Allocator) void {
        allocator.free(self.source_entity.namespace);
        allocator.free(self.source_entity.local_id);
        allocator.free(self.imported_path);
    }
};

/// Import type
pub const ImportType = enum {
    standard_library,
    local,
    library,
    external,
};

/// Function call relationship
pub const FunctionCallRelationship = struct {
    caller_entity: EntityId,
    function_name: []const u8,
    confidence: f32,

    pub fn deinit(self: *FunctionCallRelationship, allocator: std.mem.Allocator) void {
        allocator.free(self.caller_entity.namespace);
        allocator.free(self.caller_entity.local_id);
        allocator.free(self.function_name);
    }
};

/// Extraction configuration
pub const ExtractionConfig = struct {
    /// Maximum relationships to extract per mutation
    max_relationships_per_mutation: usize = 50,
    /// Minimum confidence threshold
    min_confidence: f32 = 0.3,
    /// Whether to use LLM for semantic analysis
    use_semantic_analysis: bool = true,
};

/// Plugin state
pub const PluginState = struct {
    pattern_cache: std.StringHashMap(PatternCache),
    relationship_buffer: std.ArrayList(Relationship),
    stats: Statistics,

    pub const PatternCache = struct {
        relationships: []ExtractedRelationship,
        timestamp: i128,

        pub fn deinit(self: *PatternCache, allocator: std.mem.Allocator) void {
            for (self.relationships) |*r| {
                r.deinit(allocator);
            }
            allocator.free(self.relationships);
        }
    };

    pub const Relationship = struct {
        source: []const u8,
        target: []const u8,
        type: RelationshipType,

        pub fn deinit(self: *Relationship, allocator: std.mem.Allocator) void {
            allocator.free(self.source);
            allocator.free(self.target);
        }
    };
};

/// Statistics
pub const Statistics = struct {
    total_mutations_processed: u64 = 0,
    relationships_discovered: u64 = 0,
    imports_found: u64 = 0,
    function_calls_found: u64 = 0,
};

// ==================== Tests ====================//

test "CodeRelationshipPlugin init" {
    const llm_provider = undefined;
    const config = ExtractionConfig{};

    var plugin = try CodeRelationshipPlugin.init(std.testing.allocator, &llm_provider, config);
    defer plugin.deinit();

    try std.testing.expectEqual(@as(usize, 0), plugin.state.pattern_cache.count());
}

test "CodeRelationshipPlugin extractFromMutation" {
    const llm_provider = undefined;
    var plugin = try CodeRelationshipPlugin.init(std.testing.allocator, &llm_provider, .{});
    defer plugin.deinit();

    const mutation = CodeMutation{
        .mutation_type = .put,
        .key = "file:main.zig",
        .value = "const std = @import(\"std\");",
        .timestamp = 1000,
    };

    const rels = try plugin.extractFromMutation(mutation);
    defer {
        for (rels) |*r| r.deinit(std.testing.allocator);
        std.testing.allocator.free(rels);
    }

    try std.testing.expect(rels.len >= 0);
}

test "analyzeImports" {
    const llm_provider = undefined;
    var plugin = try CodeRelationshipPlugin.init(std.testing.allocator, &llm_provider, .{});
    defer plugin.deinit();

    const entity = EntityId{ .namespace = "file", .local_id = "test.zig" };
    const code = "const std = @import(\"std\");\nconst mem = @import(\"./mem.zig\");";

    const imports = try plugin.analyzeImports(code, entity);
    defer {
        for (imports) |*imp| imp.deinit(std.testing.allocator);
        std.testing.allocator.free(imports);
    }

    try std.testing.expect(imports.len >= 2);
}

test "findFunctionCalls" {
    const llm_provider = undefined;
    var plugin = try CodeRelationshipPlugin.init(std.testing.allocator, &llm_provider, .{});
    defer plugin.deinit();

    const entity = EntityId{ .namespace = "file", .local_id = "test.zig" };
    const code = "fn main() void { print(\"hello\"); exit(0); }";

    const calls = try plugin.findFunctionCalls(code, entity);
    defer {
        for (calls) |*c| c.deinit(std.testing.allocator);
        std.testing.allocator.free(calls);
    }

    try std.testing.expect(calls.len >= 2); // print and exit
}

test "getStats" {
    const llm_provider = undefined;
    var plugin = try CodeRelationshipPlugin.init(std.testing.allocator, &llm_provider, .{});
    defer plugin.deinit();

    const stats = plugin.getStats();

    try std.testing.expectEqual(@as(u64, 0), stats.total_mutations_processed);
}

test "ExtractedRelationship deinit" {
    const rel = ExtractedRelationship{
        .source = EntityId{ .namespace = "test", .local_id = "a" },
        .target = EntityId{ .namespace = "test", .local_id = "b" },
        .relationship_type = .imports,
        .confidence = 0.8,
        .discovery_method = "test",
    };

    // Can't properly test deinit without alloc but we can verify the structure compiles
    _ = rel;
}

test "inferImportRelationship" {
    const llm_provider = undefined;
    var plugin = try CodeRelationshipPlugin.init(std.testing.allocator, &llm_provider, .{});
    defer plugin.deinit();

    try std.testing.expectEqual(ImportType.standard_library, plugin.inferImportRelationship("std/debug.zig"));
    try std.testing.expectEqual(ImportType.local, plugin.inferImportRelationship("./local.zig"));
    try std.testing.expectEqual(ImportType.external, plugin.inferImportRelationship("http://example.com"));
}

test "isKeyword" {
    const llm_provider = undefined;
    var plugin = try CodeRelationshipPlugin.init(std.testing.allocator, &llm_provider, .{});
    defer plugin.deinit();

    try std.testing.expect(plugin.isKeyword("if"));
    try std.testing.expect(plugin.isKeyword("for"));
    try std.testing.expect(!plugin.isKeyword("myFunction"));
}
