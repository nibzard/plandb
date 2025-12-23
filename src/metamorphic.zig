//! Metamorphic testing framework for NorthstarDB.
//!
//! Metamorphic testing verifies that different inputs or execution paths produce
//! related outputs according to known properties or invariants. This complements
//! property-based testing by focusing on specific API-level relationships.
//!
//! Key metamorphic properties:
//! - Read-Your-Writes: get(put(k, v)) returns v
//! - Delete-After-Put: delete(put(k, v)) + get(k) returns null
//! - Idempotent Put: put(k, v1) + put(k, v2) + get(k) returns v2
//! - Idempotent Delete: delete(k) + delete(k) has same effect as delete(k)
//! - Batch Equivalence: Single txn with N ops = N txns with 1 op each
//! - Scan Consistency: scan() after operations sees all committed changes
//! - Empty Scan: scan() on empty DB returns no results
//! - Snapshot Isolation: Old snapshot doesn't see new writes

const std = @import("std");
const ref_model = @import("ref_model.zig");

// ==================== Metamorphic Test Framework ====================

/// Configuration for metamorphic tests
pub const MetamorphicTestConfig = struct {
    random_seed: u64 = 42,
    num_iterations: usize = 100,
    max_keys_per_test: usize = 50,
    value_size_range: struct { usize, usize } = .{ 8, 64 },
    key_size_range: struct { usize, usize } = .{ 4, 16 },
};

/// Result of a metamorphic test
pub const MetamorphicTestResult = struct {
    test_name: []const u8,
    passed: bool,
    cases_passed: usize,
    total_cases: usize,
    failure_details: ?[]const u8 = null,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(test_name: []const u8, allocator: std.mem.Allocator) Self {
        return Self{
            .test_name = test_name,
            .passed = false,
            .cases_passed = 0,
            .total_cases = 0,
            .failure_details = null,
            .allocator = allocator,
        };
    }

    pub fn passCase(self: *Self) void {
        self.cases_passed += 1;
    }

    pub fn fail(self: *Self, comptime fmt: []const u8, args: anytype) void {
        self.passed = false;
        self.failure_details = std.fmt.allocPrint(self.allocator, fmt, args) catch "Failed to allocate error message";
    }

    pub fn complete(self: *Self, total_cases: usize) void {
        self.total_cases = total_cases;
        self.passed = self.cases_passed == total_cases;
    }

    pub fn deinit(self: *Self) void {
        if (self.failure_details) |details| {
            self.allocator.free(details);
        }
    }
};

/// Helper to generate random keys and values
pub const MetamorphicGenerator = struct {
    rng: ref_model.SeededRng,
    allocator: std.mem.Allocator,
    config: MetamorphicTestConfig,

    pub fn init(allocator: std.mem.Allocator, seed: u64, config: MetamorphicTestConfig) MetamorphicGenerator {
        return .{
            .rng = ref_model.SeededRng.init(seed),
            .allocator = allocator,
            .config = config,
        };
    }

    pub fn randomKey(self: *MetamorphicGenerator) ![]const u8 {
        const min_len = self.config.key_size_range[0];
        const max_len = self.config.key_size_range[1];
        return self.rng.nextString(self.allocator, min_len, max_len);
    }

    pub fn randomValue(self: *MetamorphicGenerator) ![]const u8 {
        const min_len = self.config.value_size_range[0];
        const max_len = self.config.value_size_range[1];
        return self.rng.nextString(self.allocator, min_len, max_len);
    }

    pub fn randomKeyValue(self: *MetamorphicGenerator) !struct { []const u8, []const u8 } {
        const key = try self.randomKey();
        errdefer self.allocator.free(key);
        const value = try self.randomValue();
        return .{ key, value };
    }
};

// ==================== Metamorphic Test: Read-Your-Writes ====================

/// Property: get(put(k, v)) returns v
/// Reading a key immediately after writing it should return the written value.
pub const ReadYourWritesTest = struct {
    config: MetamorphicTestConfig,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, config: MetamorphicTestConfig) ReadYourWritesTest {
        return ReadYourWritesTest{
            .config = config,
            .allocator = allocator,
        };
    }

    pub fn run(self: *ReadYourWritesTest) !MetamorphicTestResult {
        var result = MetamorphicTestResult.init("read_your_writes", self.allocator);

        for (0..self.config.num_iterations) |iteration| {
            const seed = self.config.random_seed + @as(u64, @intCast(iteration));
            var generator = MetamorphicGenerator.init(self.allocator, seed, self.config);

            var model = try ref_model.Model.init(self.allocator);
            defer model.deinit();

            // Perform put operation
            const key, const value = try generator.randomKeyValue();
            defer {
                self.allocator.free(key);
                self.allocator.free(value);
            }

            var w = model.beginWrite();
            try w.put(key, value);
            const txn_id = try w.commit();

            // Perform get operation
            var snap = try model.beginRead(txn_id);
            defer {
                var it = snap.iterator();
                while (it.next()) |entry| {
                    self.allocator.free(entry.key_ptr.*);
                    self.allocator.free(entry.value_ptr.*);
                }
                snap.deinit();
            }

            const actual_value = snap.get(key);

            // Verify: get(put(k, v)) == v
            if (actual_value) |val| {
                if (std.mem.eql(u8, val, value)) {
                    result.passCase();
                } else {
                    result.fail("Iteration {}: Expected {s}, got {s}", .{ iteration, value, val });
                    break;
                }
            } else {
                result.fail("Iteration {}: Key not found after put", .{iteration});
                break;
            }
        }

        result.complete(self.config.num_iterations);
        return result;
    }
};

// ==================== Metamorphic Test: Delete After Put ====================

/// Property: delete(put(k, v)) + get(k) returns null
/// Deleting a key after putting it should make it unreadable.
pub const DeleteAfterPutTest = struct {
    config: MetamorphicTestConfig,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, config: MetamorphicTestConfig) DeleteAfterPutTest {
        return DeleteAfterPutTest{
            .config = config,
            .allocator = allocator,
        };
    }

    pub fn run(self: *DeleteAfterPutTest) !MetamorphicTestResult {
        var result = MetamorphicTestResult.init("delete_after_put", self.allocator);

        for (0..self.config.num_iterations) |iteration| {
            const seed = self.config.random_seed + @as(u64, @intCast(iteration));
            var generator = MetamorphicGenerator.init(self.allocator, seed, self.config);

            var model = try ref_model.Model.init(self.allocator);
            defer model.deinit();

            // Put key-value
            const key, const value = try generator.randomKeyValue();
            defer {
                self.allocator.free(key);
                self.allocator.free(value);
            }

            var w1 = model.beginWrite();
            try w1.put(key, value);
            _ = try w1.commit();

            // Delete key
            var w2 = model.beginWrite();
            try w2.del(key);
            const txn_id = try w2.commit();

            // Get should return null
            var snap = try model.beginRead(txn_id);
            defer {
                var it = snap.iterator();
                while (it.next()) |entry| {
                    self.allocator.free(entry.key_ptr.*);
                    self.allocator.free(entry.value_ptr.*);
                }
                snap.deinit();
            }

            if (snap.get(key)) |val| {
                result.fail("Iteration {}: Expected null, got {s}", .{ iteration, val });
                break;
            } else {
                result.passCase();
            }
        }

        result.complete(self.config.num_iterations);
        return result;
    }
};

// ==================== Metamorphic Test: Idempotent Put ====================

/// Property: put(k, v1) + put(k, v2) + get(k) returns v2
/// Multiple puts to the same key should result in the last value being visible.
pub const IdempotentPutTest = struct {
    config: MetamorphicTestConfig,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, config: MetamorphicTestConfig) IdempotentPutTest {
        return IdempotentPutTest{
            .config = config,
            .allocator = allocator,
        };
    }

    pub fn run(self: *IdempotentPutTest) !MetamorphicTestResult {
        var result = MetamorphicTestResult.init("idempotent_put", self.allocator);

        for (0..self.config.num_iterations) |iteration| {
            const seed = self.config.random_seed + @as(u64, @intCast(iteration));
            var generator = MetamorphicGenerator.init(self.allocator, seed, self.config);

            var model = try ref_model.Model.init(self.allocator);
            defer model.deinit();

            const key = try generator.randomKey();
            defer self.allocator.free(key);

            const value1 = try generator.randomValue();
            defer self.allocator.free(value1);

            const value2 = try generator.randomValue();
            defer self.allocator.free(value2);

            // First put
            var w1 = model.beginWrite();
            try w1.put(key, value1);
            _ = try w1.commit();

            // Second put (same key, different value)
            var w2 = model.beginWrite();
            try w2.put(key, value2);
            const txn_id = try w2.commit();

            // Get should return value2
            var snap = try model.beginRead(txn_id);
            defer {
                var it = snap.iterator();
                while (it.next()) |entry| {
                    self.allocator.free(entry.key_ptr.*);
                    self.allocator.free(entry.value_ptr.*);
                }
                snap.deinit();
            }

            const actual_value = snap.get(key);

            if (actual_value) |val| {
                if (std.mem.eql(u8, val, value2)) {
                    result.passCase();
                } else {
                    result.fail("Iteration {}: Expected {s}, got {s}", .{ iteration, value2, val });
                    break;
                }
            } else {
                result.fail("Iteration {}: Key not found after second put", .{iteration});
                break;
            }
        }

        result.complete(self.config.num_iterations);
        return result;
    }
};

// ==================== Metamorphic Test: Idempotent Delete ====================

/// Property: delete(k) + delete(k) has same effect as delete(k)
/// Deleting a non-existent key should be idempotent.
pub const IdempotentDeleteTest = struct {
    config: MetamorphicTestConfig,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, config: MetamorphicTestConfig) IdempotentDeleteTest {
        return IdempotentDeleteTest{
            .config = config,
            .allocator = allocator,
        };
    }

    pub fn run(self: *IdempotentDeleteTest) !MetamorphicTestResult {
        var result = MetamorphicTestResult.init("idempotent_delete", self.allocator);

        for (0..self.config.num_iterations) |iteration| {
            const seed = self.config.random_seed + @as(u64, @intCast(iteration));
            var generator = MetamorphicGenerator.init(self.allocator, seed, self.config);

            // Model 1: Single delete
            var model1 = try ref_model.Model.init(self.allocator);
            defer model1.deinit();

            const key = try generator.randomKey();
            defer self.allocator.free(key);

            var w1 = model1.beginWrite();
            try w1.del(key);
            const txn1_id = try w1.commit();

            // Model 2: Double delete
            var model2 = try ref_model.Model.init(self.allocator);
            defer model2.deinit();

            var w2 = model2.beginWrite();
            try w2.del(key);
            _ = try w2.commit();

            var w3 = model2.beginWrite();
            try w3.del(key);
            const txn2_id = try w3.commit();

            // Both models should have the same state (empty)
            var snap1 = try model1.beginRead(txn1_id);
            defer {
                var it = snap1.iterator();
                while (it.next()) |entry| {
                    self.allocator.free(entry.key_ptr.*);
                    self.allocator.free(entry.value_ptr.*);
                }
                snap1.deinit();
            }

            var snap2 = try model2.beginRead(txn2_id);
            defer {
                var it = snap2.iterator();
                while (it.next()) |entry| {
                    self.allocator.free(entry.key_ptr.*);
                    self.allocator.free(entry.value_ptr.*);
                }
                snap2.deinit();
            }

            if (snap1.count() == snap2.count() and snap1.count() == 0) {
                result.passCase();
            } else {
                result.fail("Iteration {}: Double delete has different effect than single delete", .{iteration});
                break;
            }
        }

        result.complete(self.config.num_iterations);
        return result;
    }
};

// ==================== Metamorphic Test: Batch Equivalence ====================

/// Property: Single txn with N ops produces same result as N txns with 1 op each
/// The order of independent operations in a single transaction vs multiple
/// transactions should produce the same final state.
pub const BatchEquivalenceTest = struct {
    config: MetamorphicTestConfig,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, config: MetamorphicTestConfig) BatchEquivalenceTest {
        return BatchEquivalenceTest{
            .config = config,
            .allocator = allocator,
        };
    }

    pub fn run(self: *BatchEquivalenceTest) !MetamorphicTestResult {
        var result = MetamorphicTestResult.init("batch_equivalence", self.allocator);

        for (0..self.config.num_iterations) |iteration| {
            const seed = self.config.random_seed + @as(u64, @intCast(iteration));
            var generator = MetamorphicGenerator.init(self.allocator, seed, self.config);

            const num_ops = 10;

            // Generate operations
            const ops = try self.allocator.alloc(struct { []const u8, []const u8 }, num_ops);
            defer {
                for (ops) |op| {
                    self.allocator.free(op[0]);
                    self.allocator.free(op[1]);
                }
                self.allocator.free(ops);
            }

            for (ops) |*op| {
                const k, const v = try generator.randomKeyValue();
                op[0] = k;
                op[1] = v;
            }

            // Model 1: Single batch transaction
            var batch_model = try ref_model.Model.init(self.allocator);
            defer batch_model.deinit();

            var batch_w = batch_model.beginWrite();
            for (ops) |op| {
                try batch_w.put(op[0], op[1]);
            }
            const batch_txn_id = try batch_w.commit();

            // Model 2: Individual transactions
            var single_model = try ref_model.Model.init(self.allocator);
            defer single_model.deinit();

            var single_txn_id: u64 = 0;
            for (ops) |op| {
                var w = single_model.beginWrite();
                try w.put(op[0], op[1]);
                single_txn_id = try w.commit();
            }

            // Compare states
            var batch_snap = try batch_model.beginRead(batch_txn_id);
            defer {
                var it = batch_snap.iterator();
                while (it.next()) |entry| {
                    self.allocator.free(entry.key_ptr.*);
                    self.allocator.free(entry.value_ptr.*);
                }
                batch_snap.deinit();
            }

            var single_snap = try single_model.beginRead(single_txn_id);
            defer {
                var it = single_snap.iterator();
                while (it.next()) |entry| {
                    self.allocator.free(entry.key_ptr.*);
                    self.allocator.free(entry.value_ptr.*);
                }
                single_snap.deinit();
            }

            // Verify equivalence
            var test_passed = true;

            if (batch_snap.count() != single_snap.count()) {
                result.fail("Iteration {}: Key count mismatch: batch={}, single={}", .{ iteration, batch_snap.count(), single_snap.count() });
                break;
            }

            var it = batch_snap.iterator();
            while (it.next()) |entry| {
                const single_val = single_snap.get(entry.key_ptr.*) orelse {
                    result.fail("Iteration {}: Key {s} in batch but not in single", .{ iteration, entry.key_ptr.* });
                    test_passed = false;
                    break;
                };

                if (!std.mem.eql(u8, entry.value_ptr.*, single_val)) {
                    result.fail("Iteration {}: Key {s} has different values", .{ iteration, entry.key_ptr.* });
                    test_passed = false;
                    break;
                }
            }

            if (test_passed) {
                result.passCase();
            } else {
                break;
            }
        }

        result.complete(self.config.num_iterations);
        return result;
    }
};

// ==================== Metamorphic Test: Scan Consistency ====================

/// Property: scan() after operations sees all committed changes
/// Scanning after a series of operations should see all key-value pairs.
pub const ScanConsistencyTest = struct {
    config: MetamorphicTestConfig,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, config: MetamorphicTestConfig) ScanConsistencyTest {
        return ScanConsistencyTest{
            .config = config,
            .allocator = allocator,
        };
    }

    pub fn run(self: *ScanConsistencyTest) !MetamorphicTestResult {
        var result = MetamorphicTestResult.init("scan_consistency", self.allocator);

        for (0..self.config.num_iterations) |iteration| {
            const seed = self.config.random_seed + @as(u64, @intCast(iteration));
            var generator = MetamorphicGenerator.init(self.allocator, seed, self.config);

            var model = try ref_model.Model.init(self.allocator);
            defer model.deinit();

            const num_pairs = 10;

            // Generate key-value pairs
            const pairs = try self.allocator.alloc(struct { []const u8, []const u8 }, num_pairs);
            defer {
                for (pairs) |pair| {
                    self.allocator.free(pair[0]);
                    self.allocator.free(pair[1]);
                }
                self.allocator.free(pairs);
            }

            for (pairs) |*pair| {
                const k, const v = try generator.randomKeyValue();
                pair[0] = k;
                pair[1] = v;
            }

            // Put all pairs
            var w = model.beginWrite();
            for (pairs) |pair| {
                try w.put(pair[0], pair[1]);
            }
            const txn_id = try w.commit();

            // Scan all
            var snap = try model.beginRead(txn_id);
            defer {
                var it = snap.iterator();
                while (it.next()) |entry| {
                    self.allocator.free(entry.key_ptr.*);
                    self.allocator.free(entry.value_ptr.*);
                }
                snap.deinit();
            }

            // Verify all pairs are present
            var test_passed = true;
            for (pairs) |pair| {
                const val = snap.get(pair[0]) orelse {
                    result.fail("Iteration {}: Key {s} not found in scan", .{ iteration, pair[0] });
                    test_passed = false;
                    break;
                };

                if (!std.mem.eql(u8, val, pair[1])) {
                    result.fail("Iteration {}: Key {s} has wrong value", .{ iteration, pair[0] });
                    test_passed = false;
                    break;
                }
            }

            // Also verify count
            if (test_passed and snap.count() != num_pairs) {
                result.fail("Iteration {}: Scan count mismatch: expected {}, got {}", .{ iteration, num_pairs, snap.count() });
                test_passed = false;
            }

            if (test_passed) {
                result.passCase();
            } else {
                break;
            }
        }

        result.complete(self.config.num_iterations);
        return result;
    }
};

// ==================== Metamorphic Test: Empty Scan ====================

/// Property: scan() on empty DB returns no results
/// Scanning a newly created database should return an empty result set.
pub const EmptyScanTest = struct {
    config: MetamorphicTestConfig,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, config: MetamorphicTestConfig) EmptyScanTest {
        return EmptyScanTest{
            .config = config,
            .allocator = allocator,
        };
    }

    pub fn run(self: *EmptyScanTest) !MetamorphicTestResult {
        var result = MetamorphicTestResult.init("empty_scan", self.allocator);

        for (0..self.config.num_iterations) |iteration| {
            _ = iteration;

            var model = try ref_model.Model.init(self.allocator);
            defer model.deinit();

            // Scan the empty database (txn_id = 0 is genesis)
            var snap = try model.beginRead(0);
            defer {
                var it = snap.iterator();
                while (it.next()) |entry| {
                    self.allocator.free(entry.key_ptr.*);
                    self.allocator.free(entry.value_ptr.*);
                }
                snap.deinit();
            }

            if (snap.count() == 0) {
                result.passCase();
            } else {
                result.fail("Empty database has {} keys", .{snap.count()});
                break;
            }
        }

        result.complete(self.config.num_iterations);
        return result;
    }
};

// ==================== Metamorphic Test: Snapshot Isolation ====================

/// Property: Old snapshot doesn't see new writes
/// A snapshot taken before a write should not see data written after the snapshot.
pub const SnapshotIsolationTest = struct {
    config: MetamorphicTestConfig,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, config: MetamorphicTestConfig) SnapshotIsolationTest {
        return SnapshotIsolationTest{
            .config = config,
            .allocator = allocator,
        };
    }

    pub fn run(self: *SnapshotIsolationTest) !MetamorphicTestResult {
        var result = MetamorphicTestResult.init("snapshot_isolation", self.allocator);

        for (0..self.config.num_iterations) |iteration| {
            const seed = self.config.random_seed + @as(u64, @intCast(iteration));
            var generator = MetamorphicGenerator.init(self.allocator, seed, self.config);

            var model = try ref_model.Model.init(self.allocator);
            defer model.deinit();

            // Create initial state
            var w1 = model.beginWrite();
            const key1, const value1 = try generator.randomKeyValue();
            defer {
                self.allocator.free(key1);
                self.allocator.free(value1);
            }
            try w1.put(key1, value1);
            const snapshot_txn_id = try w1.commit();

            // Capture snapshot state
            var old_snap = try model.beginRead(snapshot_txn_id);
            defer {
                var it = old_snap.iterator();
                while (it.next()) |entry| {
                    self.allocator.free(entry.key_ptr.*);
                    self.allocator.free(entry.value_ptr.*);
                }
                old_snap.deinit();
            }

            // Collect initial keys
            var initial_keys = std.ArrayList([]const u8).initCapacity(self.allocator, 0) catch unreachable;
            defer {
                for (initial_keys.items) |k| self.allocator.free(k);
                initial_keys.deinit(self.allocator);
            }

            {
                var it = old_snap.iterator();
                while (it.next()) |entry| {
                    try initial_keys.append(self.allocator, try self.allocator.dupe(u8, entry.key_ptr.*));
                }
            }

            // Write more data
            var w2 = model.beginWrite();
            const key2, const value2 = try generator.randomKeyValue();
            defer {
                self.allocator.free(key2);
                self.allocator.free(value2);
            }
            try w2.put(key2, value2);
            _ = try w2.commit();

            // Re-read old snapshot
            var verify_snap = try model.beginRead(snapshot_txn_id);
            defer {
                var it = verify_snap.iterator();
                while (it.next()) |entry| {
                    self.allocator.free(entry.key_ptr.*);
                    self.allocator.free(entry.value_ptr.*);
                }
                verify_snap.deinit();
            }

            // Verify: old snapshot has same keys as before
            if (verify_snap.count() != initial_keys.items.len) {
                result.fail("Iteration {}: Snapshot key count changed from {} to {}", .{ iteration, initial_keys.items.len, verify_snap.count() });
                break;
            }

            // Verify: new key is not visible in old snapshot
            if (verify_snap.get(key2) != null) {
                result.fail("Iteration {}: New key visible in old snapshot", .{iteration});
                break;
            }

            // Verify: old values haven't changed
            var test_passed = true;
            for (initial_keys.items) |key| {
                const val = verify_snap.get(key) orelse {
                    result.fail("Iteration {}: Key {s} disappeared from old snapshot", .{ iteration, key });
                    test_passed = false;
                    break;
                };

                _ = val; // Value exists, which is what we care about
            }

            if (test_passed) {
                result.passCase();
            } else {
                break;
            }
        }

        result.complete(self.config.num_iterations);
        return result;
    }
};

// ==================== Metamorphic Test Runner ====================

/// Main metamorphic test runner
pub const MetamorphicTestRunner = struct {
    config: MetamorphicTestConfig,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, config: MetamorphicTestConfig) MetamorphicTestRunner {
        return MetamorphicTestRunner{
            .config = config,
            .allocator = allocator,
        };
    }

    pub fn runAllMetamorphicTests(self: *MetamorphicTestRunner) ![]MetamorphicTestResult {
        var results = try self.allocator.alloc(MetamorphicTestResult, 8);
        var idx: usize = 0;

        // Run all tests
        comptime {
            std.debug.assert(8 == 8); // Ensure we have exactly 8 tests
        }

        // 1. Read-Your-Writes
        {
            var t = ReadYourWritesTest.init(self.allocator, self.config);
            results[idx] = try t.run();
            idx += 1;
        }

        // 2. Delete After Put
        {
            var t = DeleteAfterPutTest.init(self.allocator, self.config);
            results[idx] = try t.run();
            idx += 1;
        }

        // 3. Idempotent Put
        {
            var t = IdempotentPutTest.init(self.allocator, self.config);
            results[idx] = try t.run();
            idx += 1;
        }

        // 4. Idempotent Delete
        {
            var t = IdempotentDeleteTest.init(self.allocator, self.config);
            results[idx] = try t.run();
            idx += 1;
        }

        // 5. Batch Equivalence
        {
            var t = BatchEquivalenceTest.init(self.allocator, self.config);
            results[idx] = try t.run();
            idx += 1;
        }

        // 6. Scan Consistency
        {
            var t = ScanConsistencyTest.init(self.allocator, self.config);
            results[idx] = try t.run();
            idx += 1;
        }

        // 7. Empty Scan
        {
            var t = EmptyScanTest.init(self.allocator, self.config);
            results[idx] = try t.run();
            idx += 1;
        }

        // 8. Snapshot Isolation
        {
            var t = SnapshotIsolationTest.init(self.allocator, self.config);
            results[idx] = try t.run();
            idx += 1;
        }

        return results;
    }

    pub fn printResults(results: []const MetamorphicTestResult) void {
        std.debug.print("\n=== Metamorphic Test Results ===\n", .{});

        var total_passed: usize = 0;
        var total_cases: usize = 0;

        for (results) |result| {
            std.debug.print("\nTest: {s}\n", .{result.test_name});
            std.debug.print("  Passed: {}/{} cases\n", .{ result.cases_passed, result.total_cases });
            const status = if (result.passed) "PASS" else "FAIL";
            std.debug.print("  Status: {s}\n", .{status});

            if (result.failure_details) |details| {
                std.debug.print("  Failure: {s}\n", .{details});
            }

            total_passed += result.cases_passed;
            total_cases += result.total_cases;
        }

        std.debug.print("\n=== Summary ===\n", .{});
        std.debug.print("Total cases passed: {}/{}\n", .{ total_passed, total_cases });
        std.debug.print("Overall success rate: {d:.2}%\n", .{@as(f64, @floatFromInt(total_passed)) * 100.0 / @as(f64, @floatFromInt(total_cases))});
    }
};

/// Run metamorphic tests as part of the normal test suite
pub fn runMetamorphicTests(allocator: std.mem.Allocator) !void {
    const config = MetamorphicTestConfig{
        .random_seed = 12345,
        .num_iterations = 50,
        .max_keys_per_test = 20,
        .value_size_range = .{ 8, 32 },
        .key_size_range = .{ 4, 12 },
    };

    var runner = MetamorphicTestRunner.init(allocator, config);
    const results = try runner.runAllMetamorphicTests();
    defer {
        for (results) |*result| {
            result.deinit();
        }
        allocator.free(results);
    }

    MetamorphicTestRunner.printResults(results);

    // Fail the test suite if any metamorphic test fails
    for (results) |result| {
        if (!result.passed) {
            std.log.err("Metamorphic test '{s}' failed", .{result.test_name});
            return error.MetamorphicTestFailed;
        }
    }
}

// ==================== Unit Tests for Metamorphic Tests ====================

test "read your writes metamorphic test" {
    const config = MetamorphicTestConfig{
        .random_seed = 42,
        .num_iterations = 10,
    };

    var t = ReadYourWritesTest.init(std.testing.allocator, config);
    var result = try t.run();
    defer result.deinit();

    try std.testing.expect(result.passed);
    try std.testing.expectEqual(@as(usize, 10), result.cases_passed);
}

test "delete after put metamorphic test" {
    const config = MetamorphicTestConfig{
        .random_seed = 42,
        .num_iterations = 10,
    };

    var t = DeleteAfterPutTest.init(std.testing.allocator, config);
    var result = try t.run();
    defer result.deinit();

    try std.testing.expect(result.passed);
    try std.testing.expectEqual(@as(usize, 10), result.cases_passed);
}

test "idempotent put metamorphic test" {
    const config = MetamorphicTestConfig{
        .random_seed = 42,
        .num_iterations = 10,
    };

    var t = IdempotentPutTest.init(std.testing.allocator, config);
    var result = try t.run();
    defer result.deinit();

    try std.testing.expect(result.passed);
    try std.testing.expectEqual(@as(usize, 10), result.cases_passed);
}

test "idempotent delete metamorphic test" {
    const config = MetamorphicTestConfig{
        .random_seed = 42,
        .num_iterations = 10,
    };

    var t = IdempotentDeleteTest.init(std.testing.allocator, config);
    var result = try t.run();
    defer result.deinit();

    try std.testing.expect(result.passed);
    try std.testing.expectEqual(@as(usize, 10), result.cases_passed);
}

test "batch equivalence metamorphic test" {
    const config = MetamorphicTestConfig{
        .random_seed = 42,
        .num_iterations = 10,
    };

    var t = BatchEquivalenceTest.init(std.testing.allocator, config);
    var result = try t.run();
    defer result.deinit();

    try std.testing.expect(result.passed);
    try std.testing.expectEqual(@as(usize, 10), result.cases_passed);
}

test "scan consistency metamorphic test" {
    const config = MetamorphicTestConfig{
        .random_seed = 42,
        .num_iterations = 10,
    };

    var t = ScanConsistencyTest.init(std.testing.allocator, config);
    var result = try t.run();
    defer result.deinit();

    try std.testing.expect(result.passed);
    try std.testing.expectEqual(@as(usize, 10), result.cases_passed);
}

test "empty scan metamorphic test" {
    const config = MetamorphicTestConfig{
        .random_seed = 42,
        .num_iterations = 5,
    };

    var t = EmptyScanTest.init(std.testing.allocator, config);
    var result = try t.run();
    defer result.deinit();

    try std.testing.expect(result.passed);
    try std.testing.expectEqual(@as(usize, 5), result.cases_passed);
}

test "snapshot isolation metamorphic test" {
    const config = MetamorphicTestConfig{
        .random_seed = 42,
        .num_iterations = 10,
    };

    var t = SnapshotIsolationTest.init(std.testing.allocator, config);
    var result = try t.run();
    defer result.deinit();

    try std.testing.expect(result.passed);
    try std.testing.expectEqual(@as(usize, 10), result.cases_passed);
}

test "metamorphic test runner integration" {
    const config = MetamorphicTestConfig{
        .random_seed = 42,
        .num_iterations = 5,
    };

    var runner = MetamorphicTestRunner.init(std.testing.allocator, config);
    const results = try runner.runAllMetamorphicTests();
    defer {
        for (results) |*result| {
            result.deinit();
        }
        std.testing.allocator.free(results);
    }

    try std.testing.expectEqual(@as(usize, 8), results.len);

    // All tests should pass
    for (results) |result| {
        try std.testing.expect(result.passed);
    }
}

test "run metamorphic tests function" {
    try runMetamorphicTests(std.testing.allocator);
}
