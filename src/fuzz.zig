//! Fuzzing harness for B+tree node decode operations.
//!
//! Implements comprehensive fuzzing for leaf and internal node decode functions
//! with valid and mutated corpora. Never crashes, never OOB - all errors are clean.
//!
//! Fuzzing targets:
//! - decodeBtreeLeafPage()
//! - decodeBtreeInternalPage() (when implemented)
//! - validateBtreeLeafStructure()

const std = @import("std");
const pager = @import("pager.zig");

const PageHeader = pager.PageHeader;
const BtreeNodeHeader = pager.BtreeNodeHeader;
const BtreeLeafEntry = pager.BtreeLeafEntry;
const BtreeLeafPayload = pager.BtreeLeafPayload;
const KeyValue = pager.KeyValue;
const encodeBtreeLeafPage = pager.encodeBtreeLeafPage;
const decodeBtreeLeafPage = pager.decodeBtreeLeafPage;
const validateBtreeLeafStructure = pager.validateBtreeLeafStructure;
const createEmptyBtreeLeaf = pager.createEmptyBtreeLeaf;
const createBtreePage = pager.createBtreePage;
const DEFAULT_PAGE_SIZE = pager.DEFAULT_PAGE_SIZE;

/// Fuzzing result tracking
pub const FuzzResult = struct {
    name: []const u8,
    iterations: usize,
    crashes: usize,
    clean_errors: usize,
    successes: usize,
    allocator: std.mem.Allocator,

    pub fn init(name: []const u8, allocator: std.mem.Allocator) FuzzResult {
        return .{
            .name = name,
            .iterations = 0,
            .crashes = 0,
            .clean_errors = 0,
            .successes = 0,
            .allocator = allocator,
        };
    }

    pub fn recordCrash(self: *FuzzResult) void {
        self.crashes += 1;
    }

    pub fn recordCleanError(self: *FuzzResult) void {
        self.clean_errors += 1;
    }

    pub fn recordSuccess(self: *FuzzResult) void {
        self.successes += 1;
    }

    pub fn summary(self: *const FuzzResult) void {
        std.debug.print(
            \\Fuzz Test: {s}
            \\  Iterations: {d}
            \\  Successes: {d}
            \\  Clean Errors: {d}
            \\  Crashes: {d}
            \\
        , .{ self.name, self.iterations, self.successes, self.clean_errors, self.crashes });
    }
};

// ==================== Corpus Generation ====================

/// Corpus entry for fuzzing
pub const CorpusEntry = struct {
    data: []const u8,
    description: []const u8,

    pub fn init(data: []const u8, description: []const u8, allocator: std.mem.Allocator) !CorpusEntry {
        const data_copy = try allocator.dupe(u8, data);
        const desc_copy = try allocator.dupe(u8, description);
        return .{
            .data = data_copy,
            .description = desc_copy,
        };
    }

    pub fn deinit(self: *CorpusEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.data);
        allocator.free(self.description);
    }
};

/// Valid corpus generator - creates well-formed B+tree pages
pub const ValidCorpusGenerator = struct {
    allocator: std.mem.Allocator,
    prng: std.Random.DefaultPrng,

    pub fn init(allocator: std.mem.Allocator, seed: u64) ValidCorpusGenerator {
        return .{
            .allocator = allocator,
            .prng = std.Random.DefaultPrng.init(seed),
        };
    }

    pub fn generateLeafPage(self: *const ValidCorpusGenerator, entry_count: usize, max_key_len: usize, max_val_len: usize) ![]const u8 {
        const buffer = try self.allocator.alloc(u8, DEFAULT_PAGE_SIZE);
        errdefer self.allocator.free(buffer);

        var prng = self.prng;
        const rand = prng.random();

        // Generate random key-value pairs
        var entries = std.ArrayList(KeyValue).initCapacity(self.allocator, entry_count) catch unreachable;
        defer {
            for (entries.items) |e| {
                self.allocator.free(e.key);
                self.allocator.free(e.value);
            }
            entries.deinit(self.allocator);
        }

        // Create entries
        for (0..entry_count) |i| {
            const key_len = rand.intRangeAtMost(usize, 1, max_key_len);
            const val_len = rand.intRangeAtMost(usize, 1, max_val_len);

            const key = try self.allocator.alloc(u8, key_len);
            const value = try self.allocator.alloc(u8, val_len);

            // Fill with deterministic but random-looking data based on index
            for (0..key_len) |j| {
                key[j] = @intCast((i * 31 + j) % 256);
            }
            for (0..val_len) |j| {
                value[j] = @intCast((i * 17 + j * 3) % 256);
            }

            try entries.append(self.allocator, .{ .key = key, .value = value });
        }

        try encodeBtreeLeafPage(1, 1, 0, entries.items, buffer);
        return buffer;
    }

    pub fn generateEmptyLeaf(self: *const ValidCorpusGenerator) ![]const u8 {
        const buffer = try self.allocator.alloc(u8, DEFAULT_PAGE_SIZE);
        try createEmptyBtreeLeaf(1, 1, 0, buffer);
        return buffer;
    }

    pub fn generateSingleEntryLeaf(self: *const ValidCorpusGenerator) ![]const u8 {
        const buffer = try self.allocator.alloc(u8, DEFAULT_PAGE_SIZE);
        const entries = [_]KeyValue{
            .{ .key = "key", .value = "value" },
        };
        try encodeBtreeLeafPage(1, 1, 0, &entries, buffer);
        return buffer;
    }

    pub fn generateFullLeaf(self: *const ValidCorpusGenerator) ![]const u8 {
        const buffer = try self.allocator.alloc(u8, DEFAULT_PAGE_SIZE);

        // Generate entries that fit in a leaf (not necessarily max, but many)
        // Each entry has overhead, so use smaller keys/values
        const entry_count = 50;
        var entries = std.ArrayList(KeyValue).initCapacity(self.allocator, entry_count) catch unreachable;
        defer {
            for (entries.items) |e| {
                self.allocator.free(e.key);
                self.allocator.free(e.value);
            }
            entries.deinit(self.allocator);
        }

        for (0..entry_count) |i| {
            // Use compact keys: 2 bytes each
            const key = try self.allocator.alloc(u8, 2);
            key[0] = @intCast(i & 0xFF);
            key[1] = @intCast((i >> 8) & 0xFF);
            // Use small values: 4 bytes each
            const value = try self.allocator.alloc(u8, 4);
            std.mem.writeInt(u32, value[0..4], @intCast(i), .little);
            try entries.append(self.allocator, .{ .key = key, .value = value });
        }

        try encodeBtreeLeafPage(1, 1, 0, entries.items, buffer);
        return buffer;
    }

    pub fn generateInternalPage(self: *const ValidCorpusGenerator, key_count: usize) ![]const u8 {
        const buffer = try self.allocator.alloc(u8, DEFAULT_PAGE_SIZE);

        // Generate a basic internal page structure
        // Internal pages have: level + key_count + right_sibling + [child_page_id, key] pairs
        var payload_data = std.ArrayList(u8).initCapacity(self.allocator, key_count * 8) catch unreachable;
        defer payload_data.deinit(self.allocator);

        // Write dummy separator keys (each key is a 4-byte integer)
        for (0..key_count) |i| {
            const key_val = @as(u32, @intCast(i * 100));
            try payload_data.appendSlice(self.allocator, std.mem.asBytes(&key_val));
            // Child page ID (4 bytes)
            const child_id = @as(u32, @intCast(i + 10));
            try payload_data.appendSlice(self.allocator, std.mem.asBytes(&child_id));
        }

        try createBtreePage(1, 1, @intCast(key_count), 0, 1, payload_data.items, buffer);
        return buffer;
    }
};

// ==================== Mutation Strategies ====================

/// Mutation strategies for fuzzing
pub const MutationStrategy = enum {
    bit_flip,
    byte_flip,
    byte_insert,
    byte_delete,
    shuffle_bytes,
    set_to_zero,
    set_to_ff,
    truncate,
    extend,
    overwrite_header,
    corrupt_checksum,
    corrupt_magic,
    corrupt_page_type,
    corrupt_key_count,

    pub const all = [_]MutationStrategy{
        .bit_flip,
        .byte_flip,
        .byte_insert,
        .byte_delete,
        .shuffle_bytes,
        .set_to_zero,
        .set_to_ff,
        .truncate,
        .extend,
        .overwrite_header,
        .corrupt_checksum,
        .corrupt_magic,
        .corrupt_page_type,
        .corrupt_key_count,
    };
};

/// Mutator for generating malformed inputs
pub const Mutator = struct {
    allocator: std.mem.Allocator,
    prng: std.Random.DefaultPrng,

    pub fn init(allocator: std.mem.Allocator, seed: u64) Mutator {
        return .{
            .allocator = allocator,
            .prng = std.Random.DefaultPrng.init(seed),
        };
    }

    pub fn mutate(self: *Mutator, original: []const u8, strategy: MutationStrategy) ![]const u8 {
        const rand = self.prng.random();

        return switch (strategy) {
            .bit_flip => self.mutateBitFlip(original, rand),
            .byte_flip => self.mutateByteFlip(original, rand),
            .byte_insert => self.mutateByteInsert(original, rand),
            .byte_delete => self.mutateByteDelete(original, rand),
            .shuffle_bytes => self.mutateShuffleBytes(original, rand),
            .set_to_zero => self.mutateSetTo(original, rand, 0),
            .set_to_ff => self.mutateSetTo(original, rand, 0xFF),
            .truncate => self.mutateTruncate(original, rand),
            .extend => self.mutateExtend(original, rand),
            .overwrite_header => self.mutateOverwriteHeader(original, rand),
            .corrupt_checksum => self.mutateCorruptChecksum(original, rand),
            .corrupt_magic => self.mutateCorruptMagic(original, rand),
            .corrupt_page_type => self.mutateCorruptPageType(original, rand),
            .corrupt_key_count => self.mutateCorruptKeyCount(original, rand),
        };
    }

    fn mutateBitFlip(self: *Mutator, original: []const u8, rand: std.Random) ![]const u8 {
        var mutated = try self.allocator.dupe(u8, original);
        errdefer self.allocator.free(mutated);

        const byte_idx = rand.intRangeLessThan(usize, 0, mutated.len);
        const bit_idx = rand.intRangeLessThan(usize, 0, 8);
        mutated[byte_idx] ^= (@as(u8, 1) << @intCast(bit_idx));

        return mutated;
    }

    fn mutateByteFlip(self: *Mutator, original: []const u8, rand: std.Random) ![]const u8 {
        var mutated = try self.allocator.dupe(u8, original);
        errdefer self.allocator.free(mutated);

        const idx = rand.intRangeLessThan(usize, 0, mutated.len);
        mutated[idx] = ~mutated[idx];

        return mutated;
    }

    fn mutateByteInsert(self: *Mutator, original: []const u8, rand: std.Random) ![]const u8 {
        const insert_pos = rand.intRangeLessThan(usize, 0, original.len);
        const insert_byte = rand.int(u8);

        var mutated = try self.allocator.alloc(u8, original.len + 1);
        @memcpy(mutated[0..insert_pos], original[0..insert_pos]);
        mutated[insert_pos] = insert_byte;
        @memcpy(mutated[insert_pos + 1 ..], original[insert_pos..]);

        return mutated;
    }

    fn mutateByteDelete(self: *Mutator, original: []const u8, rand: std.Random) ![]const u8 {
        if (original.len == 0) return error.CannotDeleteFromEmpty;

        const delete_pos = rand.intRangeLessThan(usize, 0, original.len);

        var mutated = try self.allocator.alloc(u8, original.len - 1);
        @memcpy(mutated[0..delete_pos], original[0..delete_pos]);
        @memcpy(mutated[delete_pos..], original[delete_pos + 1 ..]);

        return mutated;
    }

    fn mutateShuffleBytes(self: *Mutator, original: []const u8, rand: std.Random) ![]const u8 {
        if (original.len < 2) return self.allocator.dupe(u8, original);

        var mutated = try self.allocator.dupe(u8, original);
        errdefer self.allocator.free(mutated);

        // Fisher-Yates shuffle for a small window
        const window_size = @min(8, mutated.len);
        const window_start = rand.intRangeLessThan(usize, 0, mutated.len - window_size + 1);

        for (0..window_size) |i| {
            const j = rand.intRangeLessThan(usize, i, window_size);
            std.mem.swap(u8, &mutated[window_start + i], &mutated[window_start + j]);
        }

        return mutated;
    }

    fn mutateSetTo(self: *Mutator, original: []const u8, rand: std.Random, value: u8) ![]const u8 {
        var mutated = try self.allocator.dupe(u8, original);
        errdefer self.allocator.free(mutated);

        const count = rand.intRangeLessThan(usize, 1, @min(10, mutated.len + 1));
        const start = rand.intRangeLessThan(usize, 0, mutated.len - count + 1);

        for (0..count) |i| {
            mutated[start + i] = value;
        }

        return mutated;
    }

    fn mutateTruncate(self: *Mutator, original: []const u8, rand: std.Random) ![]const u8 {
        if (original.len == 0) return error.CannotTruncateEmpty;

        const new_len = rand.intRangeLessThan(usize, 0, original.len);
        return self.allocator.dupe(u8, original[0..new_len]);
    }

    fn mutateExtend(self: *Mutator, original: []const u8, rand: std.Random) ![]const u8 {
        const extension_len = rand.intRangeLessThan(usize, 1, 100);

        var mutated = try self.allocator.alloc(u8, original.len + extension_len);
        @memcpy(mutated[0..original.len], original);

        // Fill extension with random bytes or zeros
        for (original.len..mutated.len) |i| {
            mutated[i] = rand.int(u8);
        }

        return mutated;
    }

    fn mutateOverwriteHeader(self: *Mutator, original: []const u8, rand: std.Random) ![]const u8 {
        if (original.len < PageHeader.SIZE) return self.allocator.dupe(u8, original);

        var mutated = try self.allocator.dupe(u8, original);
        errdefer self.allocator.free(mutated);

        // Overwrite a random byte in the header
        const header_idx = rand.intRangeLessThan(usize, 0, PageHeader.SIZE);
        mutated[header_idx] = rand.int(u8);

        return mutated;
    }

    fn mutateCorruptChecksum(self: *Mutator, original: []const u8, rand: std.Random) ![]const u8 {
        _ = rand;
        if (original.len < PageHeader.SIZE) return self.allocator.dupe(u8, original);

        var mutated = try self.allocator.dupe(u8, original);
        errdefer self.allocator.free(mutated);

        // Corrupt the page_crc32c field (offset 24-27 in header)
        const checksum_offset = 24;
        if (checksum_offset + 4 <= mutated.len) {
            mutated[checksum_offset] = 0xFF;
            mutated[checksum_offset + 1] = 0xFF;
            mutated[checksum_offset + 2] = 0xFF;
            mutated[checksum_offset + 3] = 0xFF;
        }

        return mutated;
    }

    fn mutateCorruptMagic(self: *Mutator, original: []const u8, rand: std.Random) ![]const u8 {
        _ = rand;
        if (original.len < 4) return self.allocator.dupe(u8, original);

        var mutated = try self.allocator.dupe(u8, original);
        errdefer self.allocator.free(mutated);

        // Corrupt the magic number (first 4 bytes)
        mutated[0] = 0xDE;
        mutated[1] = 0xAD;
        mutated[2] = 0xBE;
        mutated[3] = 0xEF;

        return mutated;
    }

    fn mutateCorruptPageType(self: *Mutator, original: []const u8, rand: std.Random) ![]const u8 {
        _ = rand;
        if (original.len < 16) return self.allocator.dupe(u8, original);

        var mutated = try self.allocator.dupe(u8, original);
        errdefer self.allocator.free(mutated);

        // Page type is at offset 12 (1 byte)
        mutated[12] = 0xFF; // Invalid page type

        return mutated;
    }

    fn mutateCorruptKeyCount(self: *Mutator, original: []const u8, _: std.Random) ![]const u8 {
        if (original.len < PageHeader.SIZE + BtreeNodeHeader.SIZE) return self.allocator.dupe(u8, original);

        var mutated = try self.allocator.dupe(u8, original);
        errdefer self.allocator.free(mutated);

        // Key count is at offset PageHeader.SIZE + 2 (2 bytes)
        const key_count_offset = PageHeader.SIZE + 2;

        // Set to an impossibly large value
        std.mem.writeInt(u16, mutated[key_count_offset..][0..2], 0xFFFF, .little);

        return mutated;
    }
};

// ==================== Fuzzing Harness ====================

/// Fuzz harness for B+tree leaf node decode
pub fn fuzzLeafNodeDecode(allocator: std.mem.Allocator, iterations: usize, seed: u64) !FuzzResult {
    var result = FuzzResult.init("leaf_node_decode", allocator);
    var corpus_gen = ValidCorpusGenerator.init(allocator, seed);
    var mutator = Mutator.init(allocator, seed + 1);

    // Generate base valid corpus
    var base_corpus = std.ArrayList([]const u8).initCapacity(allocator, 8) catch unreachable;
    defer {
        for (base_corpus.items) |item| allocator.free(item);
        base_corpus.deinit(allocator);
    }

    try base_corpus.append(allocator, try corpus_gen.generateEmptyLeaf());
    try base_corpus.append(allocator, try corpus_gen.generateSingleEntryLeaf());
    try base_corpus.append(allocator, try corpus_gen.generateLeafPage(5, 10, 20));
    try base_corpus.append(allocator, try corpus_gen.generateLeafPage(20, 8, 32));
    try base_corpus.append(allocator, try corpus_gen.generateFullLeaf());
    try base_corpus.append(allocator, try corpus_gen.generateInternalPage(3));
    try base_corpus.append(allocator, try corpus_gen.generateInternalPage(10));

    // Add some edge cases
    {
        var tiny_buf: [10]u8 = undefined;
        @memset(&tiny_buf, 0xAA);
        try base_corpus.append(allocator, try allocator.dupe(u8, &tiny_buf));
    }

    var prng = std.Random.DefaultPrng.init(seed);
    const rand = prng.random();

    for (0..iterations) |i| {
        result.iterations += 1;

        // Select a base corpus entry
        const base_idx = rand.intRangeLessThan(usize, 0, base_corpus.items.len);
        const base = base_corpus.items[base_idx];

        // Decide whether to use base directly or mutate
        const use_mutation = rand.float(f64) < 0.8; // 80% mutation rate

        const test_input = if (use_mutation) blk: {
            const strategy_idx = rand.intRangeLessThan(usize, 0, MutationStrategy.all.len);
            const strategy = MutationStrategy.all[strategy_idx];

            break :blk mutator.mutate(base, strategy) catch base;
        } else base;

        // Ensure we free the input if it was mutated
        defer {
            if (use_mutation) {
                if (test_input.ptr != base.ptr) {
                    allocator.free(test_input);
                }
            }
        }

        // Test decodeBtreeLeafPage - should never crash
        const decode_result = decodeBtreeLeafPage(test_input, allocator);

        if (decode_result) |decoded| {
            // Success - clean up
            result.recordSuccess();
            for (decoded) |entry| {
                allocator.free(entry.key);
                allocator.free(entry.value);
            }
            allocator.free(decoded);
        } else |err| {
            // Error - should be a clean error, not a crash
            result.recordCleanError();

            // Verify it's a known clean error type
            const is_clean_error = switch (err) {
                error.BufferTooSmall, error.InvalidPageType,
                error.EntryTooShort, error.EntryIncomplete,
                error.InvalidEntryOffset => true,
                else => blk: {
                    // Unknown error - might be a problem
                    std.debug.print("WARNING: Unexpected error in fuzz iteration {}: {}\n", .{ i, err });
                    break :blk false;
                },
            };

            if (!is_clean_error) {
                result.recordCrash();
            }
        }

        // Test validateBtreeLeafStructure - should also never crash
        _ = validateBtreeLeafStructure(test_input) catch {
            // Validation failed with clean error - expected for malformed inputs
        };
    }

    return result;
}

/// Run all fuzzing tests
pub fn runAllFuzzTests(allocator: std.mem.Allocator, iterations_per_test: usize) !void {
    std.debug.print("\n=== Fuzzing Tests ===\n\n", .{});

    // Test 1: Leaf node decode fuzzing
    {
        std.debug.print("Running: leaf_node_decode fuzz test ({d} iterations)...\n", .{iterations_per_test});
        var result = try fuzzLeafNodeDecode(allocator, iterations_per_test, 12345);
        result.summary();

        if (result.crashes > 0) {
            std.debug.print("FAIL: {d} crashes detected!\n", .{result.crashes});
            return error.FuzzTestFailed;
        }
    }

    std.debug.print("\nAll fuzz tests passed!\n", .{});
}

// ==================== Unit Tests ====================

test "ValidCorpusGenerator generates valid leaf page" {
    const allocator = std.testing.allocator;
    var gen = ValidCorpusGenerator.init(allocator, 42);

    const page = try gen.generateLeafPage(10, 20, 50);
    defer allocator.free(page);

    try std.testing.expectEqual(DEFAULT_PAGE_SIZE, page.len);

    // Should decode successfully
    const entries = try decodeBtreeLeafPage(page, allocator);
    defer {
        for (entries) |e| {
            allocator.free(e.key);
            allocator.free(e.value);
        }
        allocator.free(entries);
    }

    try std.testing.expectEqual(@as(usize, 10), entries.len);
}

test "Mutator bit_flip produces valid mutation" {
    const allocator = std.testing.allocator;
    var gen = ValidCorpusGenerator.init(allocator, 42);
    var mutator = Mutator.init(allocator, 123);

    const original = try gen.generateSingleEntryLeaf();
    defer allocator.free(original);

    const mutated = try mutator.mutate(original, .bit_flip);
    defer allocator.free(mutated);

    try std.testing.expectEqual(original.len, mutated.len);

    // Should differ in at least one byte
    var differences: usize = 0;
    for (original, mutated) |o, m| {
        if (o != m) differences += 1;
    }
    try std.testing.expect(differences > 0);
}

test "Mutator truncate produces shorter output" {
    const allocator = std.testing.allocator;
    var gen = ValidCorpusGenerator.init(allocator, 42);
    var mutator = Mutator.init(allocator, 123);

    const original = try gen.generateSingleEntryLeaf();
    defer allocator.free(original);

    const mutated = try mutator.mutate(original, .truncate);
    defer allocator.free(mutated);

    try std.testing.expect(mutated.len < original.len);
}

test "fuzzLeafNodeDecode handles all mutations cleanly" {
    const allocator = std.testing.allocator;

    // Small fuzz test for unit test verification
    const result = try fuzzLeafNodeDecode(allocator, 100, 999);

    // Should have no crashes
    try std.testing.expectEqual(@as(usize, 0), result.crashes);
}

test "Mutator all strategies produce valid outputs" {
    const allocator = std.testing.allocator;
    var gen = ValidCorpusGenerator.init(allocator, 42);
    var mutator = Mutator.init(allocator, 123);

    const original = try gen.generateSingleEntryLeaf();
    defer allocator.free(original);

    for (MutationStrategy.all) |strategy| {
        const mutated = mutator.mutate(original, strategy) catch |err| {
            // Some mutations may fail (e.g., truncate empty buffer)
            std.debug.print("Strategy {s} failed: {}\n", .{ @tagName(strategy), err });
            continue;
        };
        defer allocator.free(mutated);

        // Should be able to attempt decode without crashing
        _ = decodeBtreeLeafPage(mutated, allocator) catch {
            // Any error is fine as long as it's not a crash
        };
    }
}
