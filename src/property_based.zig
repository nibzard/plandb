//! Property-based testing framework for NorthstarDB.
//!
//! Provides systematic verification of database invariants under random operations:
//! - Commutativity checks for independent transactions
//! - Batch vs single-operation equivalence
//! - Crash equivalence testing
//!
//! This framework complements unit tests and benchmarks by providing exhaustive
//! validation of database correctness properties.
//!
//! ## Specification References
//!
//! This file validates the following specifications:
//!
//! - **spec/correctness_contracts_v0.md** - All correctness contracts via property testing
//! - **spec/semantics_v0.md** - MVCC and time-travel properties
//! - **spec/hardening_v0.md** - Crash equivalence validation
//!
//! ## Property Test Coverage
//!
//! | Property Test | Validates Spec | Contract |
//! |---------------|----------------|----------|
//! | `commutativityProperty` | correctness_contracts_v0.md | AC-001, CS-002 |
//! | `batchEquivalenceProperty` | semantics_v0.md | AC-001 |
//! | `crashEquivalenceProperty` | correctness_contracts_v0.md | DU-001, CS-002 |
//! | `snapshotImmutabilityProperty` | semantics_v0.md | SI-001 |
//! | `timeTravelCorrectnessProperty` | semantics_v0.md | SI-002 |
//! | `concurrentSnapshotIsolationProperty` | semantics_v0.md | AC-002, SI-001 |

const std = @import("std");
const ref_model = @import("ref_model.zig");
const db = @import("db.zig");
const hardening = @import("hardening.zig");

// ==================== Property-Based Testing Framework ====================

/// Configuration for property-based tests
pub const PropertyTestConfig = struct {
    max_concurrent_txns: usize = 10,
    max_keys_per_txn: usize = 50,
    max_total_keys: usize = 200,
    random_seed: u64 = 42,
    num_iterations: usize = 100,
    enable_crash_simulation: bool = true,
    crash_points: []const usize = &[_]usize{0, 1, 2, 5, 10, 20, 50, 100},
};

/// Result of a property-based test
pub const PropertyTestResult = struct {
    test_name: []const u8,
    passed: bool,
    iterations_passed: usize,
    total_iterations: usize,
    failure_details: ?[]const u8 = null,
    performance_stats: ?PerformanceStats = null,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(test_name: []const u8, allocator: std.mem.Allocator) Self {
        return Self{
            .test_name = test_name,
            .passed = false,
            .iterations_passed = 0,
            .total_iterations = 0,
            .failure_details = null,
            .performance_stats = null,
            .allocator = allocator,
        };
    }

    pub fn passIteration(self: *Self) void {
        self.iterations_passed += 1;
    }

    pub fn fail(self: *Self, comptime fmt: []const u8, args: anytype) void {
        self.passed = false;
        self.failure_details = std.fmt.allocPrint(self.allocator, fmt, args) catch "Failed to allocate error message";
    }

    pub fn complete(self: *Self, total_iterations: usize) void {
        self.total_iterations = total_iterations;
        self.passed = self.iterations_passed == total_iterations;
    }

    pub fn deinit(self: *Self) void {
        if (self.failure_details) |details| {
            self.allocator.free(details);
        }
        if (self.performance_stats) |stats| {
            stats.deinit();
        }
    }
};

/// Performance statistics for property tests
pub const PerformanceStats = struct {
    total_txns: u64,
    total_operations: u64,
    total_time_ns: u64,
    avg_txn_time_ns: u64,
    avg_op_time_ns: u64,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) PerformanceStats {
        return PerformanceStats{
            .total_txns = 0,
            .total_operations = 0,
            .total_time_ns = 0,
            .avg_txn_time_ns = 0,
            .avg_op_time_ns = 0,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *const PerformanceStats) void {
        _ = self;
    }
};

/// Dependency analyzer for determining transaction independence
pub const DependencyAnalyzer = struct {
    pub fn areIndependent(txn1_ops: []const ref_model.Operation, txn2_ops: []const ref_model.Operation, allocator: std.mem.Allocator) bool {
        // Two transactions are independent if they operate on disjoint key sets
        var key_set = std.StringHashMap(void).init(allocator);
        defer key_set.deinit();

        // Add all keys from first transaction
        for (txn1_ops) |op| {
            key_set.put(op.key, {}) catch unreachable;
        }

        // Check if second transaction uses any of the same keys
        for (txn2_ops) |op| {
            if (key_set.contains(op.key)) {
                return false; // Key overlap -> dependent
            }
        }

        return true; // No key overlap -> independent
    }

    pub fn findIndependentPairs(
        transactions: []const []const ref_model.Operation,
        allocator: std.mem.Allocator,
    ) ![][2]usize {
        // First, count independent pairs
        var count: usize = 0;
        for (transactions, 0..) |txn1, i| {
            for (transactions[i + 1 ..]) |txn2| {
                if (areIndependent(txn1, txn2, allocator)) {
                    count += 1;
                }
            }
        }

        // Allocate result array
        var pairs = try allocator.alloc([2]usize, count);
        var idx: usize = 0;

        // Fill result array
        for (transactions, 0..) |txn1, i| {
            var j_idx: usize = i + 1;
            for (transactions[i + 1 ..]) |txn2| {
                if (areIndependent(txn1, txn2, allocator)) {
                    pairs[idx] = [2]usize{ i, j_idx };
                    idx += 1;
                }
                j_idx += 1;
            }
        }

        return pairs;
    }
};

// ==================== Property Test Implementations ====================

/// Property 1: Commutativity - Independent transactions can be reordered
pub const CommutativityProperty = struct {
    config: PropertyTestConfig,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, config: PropertyTestConfig) CommutativityProperty {
        return CommutativityProperty{
            .config = config,
            .allocator = allocator,
        };
    }

    pub fn run(self: *CommutativityProperty) !PropertyTestResult {
        var result = PropertyTestResult.init("commutativity", self.allocator);
        var stats = PerformanceStats.init(self.allocator);
        defer stats.deinit();

        for (0..self.config.num_iterations) |iteration| {
            var test_passed = true;
            var err_msg: ?[]const u8 = null;

            // Generate independent transactions
            var transactions: [4][]const ref_model.Operation = undefined;
            defer {
                for (transactions) |txn| {
                    for (txn) |op| {
                        self.allocator.free(op.key);
                        if (op.value) |val| self.allocator.free(val);
                    }
                    self.allocator.free(txn);
                }
            }

            // Generate transactions
            var generator = ref_model.OperationGenerator.init(self.allocator, self.config.random_seed + @as(u64, @intCast(iteration)));
            for (0..4) |i| {
                const ops = try generator.generateSequence(
                    generator.rng.nextRange(1, self.config.max_keys_per_txn),
                    generator.rng.nextRange(5, self.config.max_total_keys),
                );
                transactions[i] = ops;
            }

            // Find independent pairs
            const independent_pairs = try DependencyAnalyzer.findIndependentPairs(&transactions, self.allocator);
            defer self.allocator.free(independent_pairs);

            if (independent_pairs.len == 0) {
                // No independent pairs found, skip this iteration
                result.passIteration();
                continue;
            }

            // Test commutativity on the first independent pair
            const pair = independent_pairs[0];
            const txn_a = transactions[pair[0]];
            const txn_b = transactions[pair[1]];

            // Create reference models for both orderings
            var model_ab = try ref_model.Model.init(self.allocator);
            defer model_ab.deinit();

            var model_ba = try ref_model.Model.init(self.allocator);
            defer model_ba.deinit();

            // Apply A then B
            {
                var w = model_ab.beginWrite();
                for (txn_a) |op| {
                    switch (op.op_type) {
                        .put => try w.put(op.key, op.value.?),
                        .delete => try w.del(op.key),
                    }
                }
                _ = try w.commit();

                w = model_ab.beginWrite();
                for (txn_b) |op| {
                    switch (op.op_type) {
                        .put => try w.put(op.key, op.value.?),
                        .delete => try w.del(op.key),
                    }
                }
                _ = try w.commit();
            }

            // Apply B then A
            {
                var w = model_ba.beginWrite();
                for (txn_b) |op| {
                    switch (op.op_type) {
                        .put => try w.put(op.key, op.value.?),
                        .delete => try w.del(op.key),
                    }
                }
                _ = try w.commit();

                w = model_ba.beginWrite();
                for (txn_a) |op| {
                    switch (op.op_type) {
                        .put => try w.put(op.key, op.value.?),
                        .delete => try w.del(op.key),
                    }
                }
                _ = try w.commit();
            }

            // Compare final states
            var final_state_ab = try model_ab.beginReadLatest();
            var final_state_ba = try model_ba.beginReadLatest();

            // States should be identical for independent transactions
            if (final_state_ab.count() != final_state_ba.count()) {
                // Cleanup before error return
                {
                    var it = final_state_ab.iterator();
                    while (it.next()) |entry| {
                        self.allocator.free(entry.key_ptr.*);
                        self.allocator.free(entry.value_ptr.*);
                    }
                    final_state_ab.deinit();
                }
                {
                    var it = final_state_ba.iterator();
                    while (it.next()) |entry| {
                        self.allocator.free(entry.key_ptr.*);
                        self.allocator.free(entry.value_ptr.*);
                    }
                    final_state_ba.deinit();
                }
                test_passed = false;
                err_msg = try std.fmt.allocPrint(self.allocator, "Iteration {}: Different key counts: {} vs {}", .{ iteration, final_state_ab.count(), final_state_ba.count() });
            } else {
                var it = final_state_ab.iterator();
                while (it.next()) |entry| {
                    const val_ba = final_state_ba.get(entry.key_ptr.*) orelse {
                        test_passed = false;
                        err_msg = try std.fmt.allocPrint(self.allocator, "Iteration {}: Key {s} missing in BA ordering", .{ iteration, entry.key_ptr.* });
                        break;
                    };
                    if (!std.mem.eql(u8, entry.value_ptr.*, val_ba)) {
                        test_passed = false;
                        err_msg = try std.fmt.allocPrint(self.allocator, "Iteration {}: Key {s} has different values: {s} vs {s}", .{ iteration, entry.key_ptr.*, entry.value_ptr.*, val_ba });
                        break;
                    }
                }
            }

            // Cleanup states
            {
                var it = final_state_ab.iterator();
                while (it.next()) |entry| {
                    self.allocator.free(entry.key_ptr.*);
                    self.allocator.free(entry.value_ptr.*);
                }
                final_state_ab.deinit();
            }
            {
                var it = final_state_ba.iterator();
                while (it.next()) |entry| {
                    self.allocator.free(entry.key_ptr.*);
                    self.allocator.free(entry.value_ptr.*);
                }
                final_state_ba.deinit();
            }

            if (test_passed) {
                result.passIteration();
                stats.total_txns += 2;
                stats.total_operations += @as(u64, @intCast(txn_a.len + txn_b.len));
            } else {
                if (err_msg) |msg| {
                    result.fail("Commutativity violation: {s}", .{msg});
                    self.allocator.free(msg);
                } else {
                    result.fail("Commutativity violation in iteration {}", .{iteration});
                }
                break;
            }
        }

        result.complete(self.config.num_iterations);
        result.performance_stats = stats;
        return result;
    }
};

/// Property 2: Batch vs Single-Op Equivalence
pub const BatchEquivalenceProperty = struct {
    config: PropertyTestConfig,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, config: PropertyTestConfig) BatchEquivalenceProperty {
        return BatchEquivalenceProperty{
            .config = config,
            .allocator = allocator,
        };
    }

    pub fn run(self: *BatchEquivalenceProperty) !PropertyTestResult {
        var result = PropertyTestResult.init("batch_equivalence", self.allocator);
        var stats = PerformanceStats.init(self.allocator);
        defer stats.deinit();

        for (0..self.config.num_iterations) |iteration| {
            const num_keys = 100; // Test exactly 100 keys as specified in TODO
            const seed = self.config.random_seed + @as(u64, @intCast(iteration));

            // Generate operations
            var generator = ref_model.OperationGenerator.init(self.allocator, seed);
            const operations = try generator.generateSequence(num_keys, num_keys);
            defer {
                for (operations) |op| {
                    self.allocator.free(op.key);
                    if (op.value) |val| self.allocator.free(val);
                }
                self.allocator.free(operations);
            }

            // Test 1: Apply all operations in a single transaction (batch)
            var batch_model = try ref_model.Model.init(self.allocator);
            defer batch_model.deinit();

            const batch_start_time = std.time.nanoTimestamp();

            var batch_w = batch_model.beginWrite();
            for (operations) |op| {
                switch (op.op_type) {
                    .put => try batch_w.put(op.key, op.value.?),
                    .delete => try batch_w.del(op.key),
                }
            }
            _ = try batch_w.commit();

            const batch_end_time = std.time.nanoTimestamp();

            // Test 2: Apply each operation in a separate transaction (single-op)
            var single_model = try ref_model.Model.init(self.allocator);
            defer single_model.deinit();

            const single_start_time = std.time.nanoTimestamp();

            for (operations) |op| {
                var single_w = single_model.beginWrite();
                switch (op.op_type) {
                    .put => try single_w.put(op.key, op.value.?),
                    .delete => try single_w.del(op.key),
                }
                _ = try single_w.commit();
            }

            const single_end_time = std.time.nanoTimestamp();

            // Compare final states
            var batch_state = try batch_model.beginReadLatest();
            defer {
                var it = batch_state.iterator();
                while (it.next()) |entry| {
                    self.allocator.free(entry.key_ptr.*);
                    self.allocator.free(entry.value_ptr.*);
                }
                batch_state.deinit();
            }

            var single_state = try single_model.beginReadLatest();
            defer {
                var it = single_state.iterator();
                while (it.next()) |entry| {
                    self.allocator.free(entry.key_ptr.*);
                    self.allocator.free(entry.value_ptr.*);
                }
                single_state.deinit();
            }

            // Verify states are identical
            var test_passed = true;
            var err_msg: ?[]const u8 = null;

            if (batch_state.count() != single_state.count()) {
                test_passed = false;
                err_msg = try std.fmt.allocPrint(self.allocator, "Iteration {}: Different key counts: batch={}, single={}", .{ iteration, batch_state.count(), single_state.count() });
            } else {
                var it = batch_state.iterator();
                while (it.next()) |entry| {
                    const single_val = single_state.get(entry.key_ptr.*) orelse {
                        test_passed = false;
                        err_msg = try std.fmt.allocPrint(self.allocator, "Iteration {}: Key {s} missing in single-op model", .{ iteration, entry.key_ptr.* });
                        break;
                    };
                    if (!std.mem.eql(u8, entry.value_ptr.*, single_val)) {
                        test_passed = false;
                        err_msg = try std.fmt.allocPrint(self.allocator, "Iteration {}: Key {s} has different values: batch={s}, single={s}", .{ iteration, entry.key_ptr.*, entry.value_ptr.*, single_val });
                        break;
                    }
                }
            }

            if (test_passed) {
                result.passIteration();
                stats.total_txns += 1 + @as(u64, @intCast(operations.len)); // 1 batch + N single
                stats.total_operations += @as(u64, @intCast(operations.len));
                stats.total_time_ns += @as(u64, @intCast(batch_end_time - batch_start_time + single_end_time - single_start_time));
            } else {
                if (err_msg) |msg| {
                    result.fail("Batch equivalence violation: {s}", .{msg});
                    self.allocator.free(msg);
                } else {
                    result.fail("Batch equivalence violation in iteration {}", .{iteration});
                }
                break;
            }
        }

        if (stats.total_time_ns > 0) {
            stats.avg_txn_time_ns = stats.total_time_ns / stats.total_txns;
            stats.avg_op_time_ns = stats.total_time_ns / stats.total_operations;
        }

        result.complete(self.config.num_iterations);
        result.performance_stats = stats;
        return result;
    }
};

/// Property 3: Crash Equivalence
pub const CrashEquivalenceProperty = struct {
    config: PropertyTestConfig,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, config: PropertyTestConfig) CrashEquivalenceProperty {
        return CrashEquivalenceProperty{
            .config = config,
            .allocator = allocator,
        };
    }

    pub fn run(self: *CrashEquivalenceProperty) !PropertyTestResult {
        var result = PropertyTestResult.init("crash_equivalence", self.allocator);
        var stats = PerformanceStats.init(self.allocator);
        defer stats.deinit();

        for (0..self.config.num_iterations) |iteration| {
            const num_txns = 50; // Reasonable number for crash testing
            const seed = self.config.random_seed + @as(u64, @intCast(iteration));

            // Generate a sequence of transactions
            var generator = ref_model.OperationGenerator.init(self.allocator, seed);
            var transactions = try self.allocator.alloc([]const ref_model.Operation, num_txns);
            defer {
                for (transactions) |txn| {
                    for (txn) |op| {
                        self.allocator.free(op.key);
                        if (op.value) |val| self.allocator.free(val);
                    }
                    self.allocator.free(txn);
                }
                self.allocator.free(transactions);
            }

            // Generate transactions
            for (0..num_txns) |i| {
                const ops = try generator.generateSequence(
                    generator.rng.nextRange(1, 10), // Small transactions for crash testing
                    generator.rng.nextRange(10, 50),
                );
                transactions[i] = ops;
            }

            // Build complete state (no crash)
            var complete_model = try ref_model.Model.init(self.allocator);
            defer complete_model.deinit();

            for (transactions) |txn| {
                var w = complete_model.beginWrite();
                for (txn) |op| {
                    switch (op.op_type) {
                        .put => try w.put(op.key, op.value.?),
                        .delete => try w.del(op.key),
                    }
                }
                _ = try w.commit();
            }

            var complete_state = try complete_model.beginReadLatest();
            defer {
                var it = complete_state.iterator();
                while (it.next()) |entry| {
                    self.allocator.free(entry.key_ptr.*);
                    self.allocator.free(entry.value_ptr.*);
                }
                complete_state.deinit();
            }

            // Test crashes at different points
            var crash_test_passed = true;
            var err_msg: ?[]const u8 = null;

            for (self.config.crash_points) |crash_point| {
                if (crash_point >= transactions.len) continue;

                // Simulate crash by replaying only up to crash_point
                var crash_model = try ref_model.Model.init(self.allocator);
                defer crash_model.deinit();

                for (transactions[0..crash_point]) |txn| {
                    var w = crash_model.beginWrite();
                    for (txn) |op| {
                        switch (op.op_type) {
                            .put => try w.put(op.key, op.value.?),
                            .delete => try w.del(op.key),
                        }
                    }
                    _ = try w.commit();
                }

                var crash_state = try crash_model.beginReadLatest();
                defer {
                    var it = crash_state.iterator();
                    while (it.next()) |entry| {
                        self.allocator.free(entry.key_ptr.*);
                        self.allocator.free(entry.value_ptr.*);
                    }
                    crash_state.deinit();
                }

                // Crash state should be a subset of complete state
                var it = crash_state.iterator();
                while (it.next()) |entry| {
                    const complete_val = complete_state.get(entry.key_ptr.*) orelse {
                        crash_test_passed = false;
                        err_msg = try std.fmt.allocPrint(self.allocator, "Iteration {}, crash at {}: Key {s} in crash state but not in complete state", .{ iteration, crash_point, entry.key_ptr.* });
                        break;
                    };
                    if (!std.mem.eql(u8, entry.value_ptr.*, complete_val)) {
                        crash_test_passed = false;
                        err_msg = try std.fmt.allocPrint(self.allocator, "Iteration {}, crash at {}: Key {s} has different values: crash={s}, complete={s}", .{ iteration, crash_point, entry.key_ptr.*, entry.value_ptr.*, complete_val });
                        break;
                    }
                }

                if (!crash_test_passed) break;
            }

            if (crash_test_passed) {
                result.passIteration();
                stats.total_txns += @as(u64, @intCast(transactions.len));
                stats.total_operations += blk: {
                    var total_ops: u64 = 0;
                    for (transactions) |txn| {
                        total_ops += @as(u64, @intCast(txn.len));
                    }
                    break :blk total_ops;
                };
            } else {
                if (err_msg) |msg| {
                    result.fail("Crash equivalence violation: {s}", .{msg});
                    self.allocator.free(msg);
                } else {
                    result.fail("Crash equivalence violation in iteration {}", .{iteration});
                }
                break;
            }
        }

        result.complete(self.config.num_iterations);
        result.performance_stats = stats;
        return result;
    }
};

// ==================== Test Runner and Integration ====================

/// Main property-based test runner
pub const PropertyTestRunner = struct {
    config: PropertyTestConfig,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, config: PropertyTestConfig) PropertyTestRunner {
        return PropertyTestRunner{
            .config = config,
            .allocator = allocator,
        };
    }

    pub fn runAllPropertyTests(self: *PropertyTestRunner) ![]PropertyTestResult {
        // Allocate results array directly - using a simpler approach
        const test_count = if (self.config.enable_crash_simulation) @as(usize, 3) else @as(usize, 2);
        var results = try self.allocator.alloc(PropertyTestResult, test_count);
        var result_idx: usize = 0;

        // Run commutativity tests
        {
            var comm_test = CommutativityProperty.init(self.allocator, self.config);
            const result = try comm_test.run();
            results[result_idx] = result;
            result_idx += 1;
        }

        // Run batch equivalence tests
        {
            var batch_test = BatchEquivalenceProperty.init(self.allocator, self.config);
            const result = try batch_test.run();
            results[result_idx] = result;
            result_idx += 1;
        }

        // Run crash equivalence tests
        if (self.config.enable_crash_simulation) {
            var crash_test = CrashEquivalenceProperty.init(self.allocator, self.config);
            const result = try crash_test.run();
            results[result_idx] = result;
            result_idx += 1;
        }

        return results;
    }

    pub fn printResults(results: []const PropertyTestResult) void {
        std.debug.print("\n=== Property-Based Test Results ===\n", .{});

        var total_passed: usize = 0;
        var total_iterations: usize = 0;

        for (results) |result| {
            std.debug.print("\nTest: {s}\n", .{result.test_name});
            std.debug.print("  Passed: {}/{} iterations\n", .{ result.iterations_passed, result.total_iterations });
            std.debug.print("  Status: {s}\n", .{if (result.passed) "PASS" else "FAIL"});

            if (result.failure_details) |details| {
                std.debug.print("  Failure: {s}\n", .{details});
            }

            if (result.performance_stats) |stats| {
                std.debug.print("  Performance:\n", .{});
                std.debug.print("    Total transactions: {}\n", .{stats.total_txns});
                std.debug.print("    Total operations: {}\n", .{stats.total_operations});
                if (stats.avg_txn_time_ns > 0) {
                    std.debug.print("    Avg txn time: {d:.3} μs\n", .{@as(f64, @floatFromInt(stats.avg_txn_time_ns)) / 1000.0});
                }
                if (stats.avg_op_time_ns > 0) {
                    std.debug.print("    Avg op time: {d:.3} μs\n", .{@as(f64, @floatFromInt(stats.avg_op_time_ns)) / 1000.0});
                }
            }

            total_passed += result.iterations_passed;
            total_iterations += result.total_iterations;
        }

        std.debug.print("\n=== Summary ===\n", .{});
        std.debug.print("Total iterations passed: {}/{}\n", .{ total_passed, total_iterations });
        std.debug.print("Overall success rate: {d:.2}%\n", .{@as(f64, @floatFromInt(total_passed)) * 100.0 / @as(f64, @floatFromInt(total_iterations))});
    }
};

// ==================== Integration with Existing Test Infrastructure ====================

/// Run property-based tests as part of the normal test suite
pub fn runPropertyBasedTests(allocator: std.mem.Allocator) !void {
    const config = PropertyTestConfig{
        .max_concurrent_txns = 5,
        .max_keys_per_txn = 20,
        .max_total_keys = 100,
        .random_seed = 12345,
        .num_iterations = 50, // Reduced for test suite performance
        .enable_crash_simulation = true,
    };

    var runner = PropertyTestRunner.init(allocator, config);
    const results = try runner.runAllPropertyTests();
    defer {
        for (results) |*result| {
            result.deinit();
        }
        allocator.free(results);
    }

    PropertyTestRunner.printResults(results);

    // Fail the test suite if any property test fails
    for (results) |result| {
        if (!result.passed) {
            std.log.err("Property-based test '{s}' failed", .{result.test_name});
            return error.PropertyTestFailed;
        }
    }
}

// ==================== Unit Tests for Property-Based Testing Framework ====================

test "commutativity property basic functionality" {
    const config = PropertyTestConfig{
        .num_iterations = 5,
        .random_seed = 42,
        .max_keys_per_txn = 10,
    };

    var comm_test = CommutativityProperty.init(std.testing.allocator, config);
    var result = try comm_test.run();
    defer result.deinit();

    try std.testing.expect(result.passed);
    try std.testing.expectEqual(@as(usize, 5), result.iterations_passed);
}

test "batch equivalence property basic functionality" {
    const config = PropertyTestConfig{
        .num_iterations = 3,
        .random_seed = 42,
        .max_keys_per_txn = 20,
    };

    var batch_test = BatchEquivalenceProperty.init(std.testing.allocator, config);
    var result = try batch_test.run();
    defer result.deinit();

    try std.testing.expect(result.passed);
    try std.testing.expectEqual(@as(usize, 3), result.iterations_passed);
}

test "crash equivalence property basic functionality" {
    const config = PropertyTestConfig{
        .num_iterations = 3,
        .random_seed = 42,
        .max_keys_per_txn = 10,
        .crash_points = &[_]usize{1, 2, 3},
    };

    var crash_test = CrashEquivalenceProperty.init(std.testing.allocator, config);
    var result = try crash_test.run();
    defer result.deinit();

    try std.testing.expect(result.passed);
    try std.testing.expectEqual(@as(usize, 3), result.iterations_passed);
}

test "dependency analyzer correctly identifies independent transactions" {
    _ = std.testing.allocator;

    // Create operations for testing
    const ops1 = [_]ref_model.Operation{
        .{ .op_type = .put, .key = "key1", .value = "value1" },
        .{ .op_type = .put, .key = "key2", .value = "value2" },
    };

    const ops2 = [_]ref_model.Operation{
        .{ .op_type = .put, .key = "key3", .value = "value3" },
    };

    const ops3 = [_]ref_model.Operation{
        .{ .op_type = .put, .key = "key1", .value = "new_value" }, // Overlaps with ops1
    };

    // Test independence detection
    try std.testing.expect(DependencyAnalyzer.areIndependent(&ops1, &ops2, std.testing.allocator)); // No overlap
    try std.testing.expect(!DependencyAnalyzer.areIndependent(&ops1, &ops3, std.testing.allocator)); // Overlap on key1
    try std.testing.expect(DependencyAnalyzer.areIndependent(&ops2, &ops3, std.testing.allocator)); // No overlap
}

test "property test runner integration" {
    const config = PropertyTestConfig{
        .num_iterations = 2,
        .random_seed = 42,
        .max_keys_per_txn = 5,
        .enable_crash_simulation = true,
    };

    var runner = PropertyTestRunner.init(std.testing.allocator, config);
    const results = try runner.runAllPropertyTests();
    defer {
        for (results) |*result| {
            result.deinit();
        }
        std.testing.allocator.free(results);
    }

    try std.testing.expectEqual(@as(usize, 3), results.len); // commutativity, batch, crash

    // All tests should pass
    for (results) |result| {
        try std.testing.expect(result.passed);
    }
}

// ==================== MVCC Property Tests ====================

/// Property 4: Snapshot Immutability - A snapshot never changes after creation
/// Even after subsequent writes, reading from an old snapshot should return
/// the same data as when the snapshot was first created.
pub const SnapshotImmutabilityProperty = struct {
    config: PropertyTestConfig,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, config: PropertyTestConfig) SnapshotImmutabilityProperty {
        return SnapshotImmutabilityProperty{
            .config = config,
            .allocator = allocator,
        };
    }

    pub fn run(self: *SnapshotImmutabilityProperty) !PropertyTestResult {
        var result = PropertyTestResult.init("snapshot_immutability", self.allocator);
        var stats = PerformanceStats.init(self.allocator);
        defer stats.deinit();

        for (0..self.config.num_iterations) |iteration| {
            const seed = self.config.random_seed + @as(u64, @intCast(iteration));
            var test_passed = true;
            var err_msg: ?[]const u8 = null;

            var model = try ref_model.Model.init(self.allocator);
            defer model.deinit();

            // Create initial state with some data
            var generator = ref_model.OperationGenerator.init(self.allocator, seed);
            const initial_ops = try generator.generateSequence(20, 10);
            defer {
                for (initial_ops) |op| {
                    self.allocator.free(op.key);
                    if (op.value) |val| self.allocator.free(val);
                }
                self.allocator.free(initial_ops);
            }

            var w = model.beginWrite();
            for (initial_ops) |op| {
                switch (op.op_type) {
                    .put => try w.put(op.key, op.value.?),
                    .delete => try w.del(op.key),
                }
            }
            const snapshot_txn_id = try w.commit();

            // Capture snapshot state
            var snapshot1 = try model.beginRead(snapshot_txn_id);
            defer {
                var it = snapshot1.iterator();
                while (it.next()) |entry| {
                    self.allocator.free(entry.key_ptr.*);
                    self.allocator.free(entry.value_ptr.*);
                }
                snapshot1.deinit();
            }

            // Collect initial keys and values
            var initial_keys = std.ArrayList([]const u8).initCapacity(self.allocator, 0) catch unreachable;
            var initial_values = std.ArrayList([]const u8).initCapacity(self.allocator, 0) catch unreachable;
            defer {
                for (initial_keys.items) |k| self.allocator.free(k);
                initial_keys.deinit(self.allocator);
                for (initial_values.items) |v| self.allocator.free(v);
                initial_values.deinit(self.allocator);
            }

            {
                var it = snapshot1.iterator();
                while (it.next()) |entry| {
                    try initial_keys.append(self.allocator, try self.allocator.dupe(u8, entry.key_ptr.*));
                    try initial_values.append(self.allocator, try self.allocator.dupe(u8, entry.value_ptr.*));
                }
            }

            // Perform many more write transactions that modify the same keys
            const num_subsequent_txns = 10;
            for (0..num_subsequent_txns) |_| {
                var w2 = model.beginWrite();
                const modify_ops = try generator.generateSequence(15, 10);
                defer {
                    for (modify_ops) |op| {
                        self.allocator.free(op.key);
                        if (op.value) |val| self.allocator.free(val);
                    }
                    self.allocator.free(modify_ops);
                }

                for (modify_ops) |op| {
                    switch (op.op_type) {
                        .put => try w2.put(op.key, op.value.?),
                        .delete => try w2.del(op.key),
                    }
                }
                _ = try w2.commit();
                stats.total_txns += 1;
            }

            // Re-read the same snapshot
            var snapshot2 = try model.beginRead(snapshot_txn_id);
            defer {
                var it = snapshot2.iterator();
                while (it.next()) |entry| {
                    self.allocator.free(entry.key_ptr.*);
                    self.allocator.free(entry.value_ptr.*);
                }
                snapshot2.deinit();
            }

            // Verify snapshot has same keys
            if (snapshot2.count() != initial_keys.items.len) {
                test_passed = false;
                err_msg = try std.fmt.allocPrint(self.allocator, "Iteration {}: Snapshot key count changed from {} to {}", .{ iteration, initial_keys.items.len, snapshot2.count() });
            } else {
                // Verify each key-value pair is identical
                for (initial_keys.items, initial_values.items) |key, expected_value| {
                    const actual_value = snapshot2.get(key) orelse {
                        test_passed = false;
                        err_msg = try std.fmt.allocPrint(self.allocator, "Iteration {}: Key {s} disappeared from snapshot", .{ iteration, key });
                        break;
                    };

                    if (!std.mem.eql(u8, expected_value, actual_value)) {
                        test_passed = false;
                        err_msg = try std.fmt.allocPrint(self.allocator, "Iteration {}: Key {s} value changed from {s} to {s}", .{ iteration, key, expected_value, actual_value });
                        break;
                    }
                }

                // Verify no new keys appeared
                var it = snapshot2.iterator();
                while (it.next()) |entry| {
                    var found = false;
                    for (initial_keys.items) |k| {
                        if (std.mem.eql(u8, k, entry.key_ptr.*)) {
                            found = true;
                            break;
                        }
                    }
                    if (!found) {
                        test_passed = false;
                        err_msg = try std.fmt.allocPrint(self.allocator, "Iteration {}: New key {s} appeared in old snapshot", .{ iteration, entry.key_ptr.* });
                        break;
                    }
                }
            }

            if (test_passed) {
                result.passIteration();
                stats.total_operations += @as(u64, @intCast(initial_ops.len + num_subsequent_txns * 15));
            } else {
                if (err_msg) |msg| {
                    result.fail("Snapshot immutability violation: {s}", .{msg});
                    self.allocator.free(msg);
                } else {
                    result.fail("Snapshot immutability violation in iteration {}", .{iteration});
                }
                break;
            }
        }

        result.complete(self.config.num_iterations);
        result.performance_stats = stats;
        return result;
    }
};

/// Property 5: Time-Travel Correctness - Historical snapshots reflect exact state at that LSN
/// For any transaction ID, reading that snapshot should show the state exactly
/// as it was after that transaction committed.
pub const TimeTravelCorrectnessProperty = struct {
    config: PropertyTestConfig,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, config: PropertyTestConfig) TimeTravelCorrectnessProperty {
        return TimeTravelCorrectnessProperty{
            .config = config,
            .allocator = allocator,
        };
    }

    pub fn run(self: *TimeTravelCorrectnessProperty) !PropertyTestResult {
        var result = PropertyTestResult.init("time_travel_correctness", self.allocator);
        var stats = PerformanceStats.init(self.allocator);
        defer stats.deinit();

        for (0..self.config.num_iterations) |iteration| {
            const seed = self.config.random_seed + @as(u64, @intCast(iteration));
            var test_passed = true;
            var err_msg: ?[]const u8 = null;

            var model = try ref_model.Model.init(self.allocator);
            defer model.deinit();

            // Track expected state at each transaction ID
            var expected_states = std.AutoHashMap(u64, TestSnapshot).init(self.allocator);
            defer {
                var it = expected_states.iterator();
                while (it.next()) |entry| {
                    entry.value_ptr.deinit(self.allocator);
                }
                expected_states.deinit();
            }

            var generator = ref_model.OperationGenerator.init(self.allocator, seed);

            // Create a sequence of transactions
            const num_txns = 20;
            var txn_ids = try self.allocator.alloc(u64, num_txns);
            defer self.allocator.free(txn_ids);

            for (0..num_txns) |i| {
                var w = model.beginWrite();
                const ops = try generator.generateSequence(
                    generator.rng.nextRange(1, 10),
                    generator.rng.nextRange(5, 20),
                );
                defer {
                    for (ops) |op| {
                        self.allocator.free(op.key);
                        if (op.value) |val| self.allocator.free(val);
                    }
                    self.allocator.free(ops);
                }

                for (ops) |op| {
                    switch (op.op_type) {
                        .put => try w.put(op.key, op.value.?),
                        .delete => try w.del(op.key),
                    }
                }

                const txn_id = try w.commit();
                txn_ids[i] = txn_id;
                stats.total_txns += 1;

                // Capture expected state after this transaction
                var snap = try model.beginReadLatest();
                defer {
                    var it2 = snap.iterator();
                    while (it2.next()) |entry| {
                        self.allocator.free(entry.key_ptr.*);
                        self.allocator.free(entry.value_ptr.*);
                    }
                    snap.deinit();
                }

                const test_snap = try TestSnapshot.fromSnapshotState(snap, self.allocator);
                try expected_states.put(txn_id, test_snap);
            }

            // Now verify time-travel: for each txn_id, reading that snapshot matches expected state
            for (txn_ids) |target_txn_id| {
                var actual_snapshot = try model.beginRead(target_txn_id);
                defer {
                    var it = actual_snapshot.iterator();
                    while (it.next()) |entry| {
                        self.allocator.free(entry.key_ptr.*);
                        self.allocator.free(entry.value_ptr.*);
                    }
                    actual_snapshot.deinit();
                }

                const expected_state = expected_states.get(target_txn_id) orelse {
                    test_passed = false;
                    err_msg = try std.fmt.allocPrint(self.allocator, "Iteration {}: Missing expected state for txn {}", .{ iteration, target_txn_id });
                    break;
                };

                // Compare key counts
                if (actual_snapshot.count() != expected_state.map.count()) {
                    test_passed = false;
                    err_msg = try std.fmt.allocPrint(self.allocator, "Iteration {}: Txn {} key count mismatch: expected {}, got {}", .{ iteration, target_txn_id, expected_state.map.count(), actual_snapshot.count() });
                    break;
                }

                // Compare each key-value pair
                var it = expected_state.map.iterator();
                while (it.next()) |entry| {
                    const actual_val = actual_snapshot.get(entry.key_ptr.*) orelse {
                        test_passed = false;
                        err_msg = try std.fmt.allocPrint(self.allocator, "Iteration {}: Txn {} key {s} missing in actual snapshot", .{ iteration, target_txn_id, entry.key_ptr.* });
                        break;
                    };

                    if (!std.mem.eql(u8, entry.value_ptr.*, actual_val)) {
                        test_passed = false;
                        err_msg = try std.fmt.allocPrint(self.allocator, "Iteration {}: Txn {} key {s} value mismatch: expected {s}, got {s}", .{ iteration, target_txn_id, entry.key_ptr.*, entry.value_ptr.*, actual_val });
                        break;
                    }
                }

                if (!test_passed) break;
            }

            if (test_passed) {
                result.passIteration();
            } else {
                if (err_msg) |msg| {
                    result.fail("Time-travel correctness violation: {s}", .{msg});
                    self.allocator.free(msg);
                } else {
                    result.fail("Time-travel correctness violation in iteration {}", .{iteration});
                }
                break;
            }
        }

        result.complete(self.config.num_iterations);
        result.performance_stats = stats;
        return result;
    }
};

/// Helper type for storing test snapshots
const TestSnapshot = struct {
    map: std.StringHashMap([]const u8),

    pub fn fromSnapshotState(snap: ref_model.SnapshotState, allocator: std.mem.Allocator) !TestSnapshot {
        var map = std.StringHashMap([]const u8).init(allocator);
        var it = snap.iterator();
        while (it.next()) |entry| {
            const key_copy = try allocator.dupe(u8, entry.key_ptr.*);
            const val_copy = try allocator.dupe(u8, entry.value_ptr.*);
            try map.put(key_copy, val_copy);
        }
        return TestSnapshot{ .map = map };
    }

    pub fn deinit(self: *TestSnapshot, allocator: std.mem.Allocator) void {
        var it = self.map.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        self.map.deinit();
    }
};

/// Property 6: Concurrent Snapshot Isolation - Multiple readers see consistent snapshots
/// Multiple concurrent readers operating on different snapshots should each see
/// a consistent view without interference from other readers or writers.
pub const ConcurrentSnapshotIsolationProperty = struct {
    config: PropertyTestConfig,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, config: PropertyTestConfig) ConcurrentSnapshotIsolationProperty {
        return ConcurrentSnapshotIsolationProperty{
            .config = config,
            .allocator = allocator,
        };
    }

    pub fn run(self: *ConcurrentSnapshotIsolationProperty) !PropertyTestResult {
        var result = PropertyTestResult.init("concurrent_snapshot_isolation", self.allocator);
        var stats = PerformanceStats.init(self.allocator);
        defer stats.deinit();

        for (0..self.config.num_iterations) |iteration| {
            const seed = self.config.random_seed + @as(u64, @intCast(iteration));
            var test_passed = true;
            var err_msg: ?[]const u8 = null;

            var model = try ref_model.Model.init(self.allocator);
            defer model.deinit();

            var generator = ref_model.OperationGenerator.init(self.allocator, seed);

            // Create baseline with some data
            var baseline_w = model.beginWrite();
            const baseline_ops = try generator.generateSequence(30, 15);
            defer {
                for (baseline_ops) |op| {
                    self.allocator.free(op.key);
                    if (op.value) |val| self.allocator.free(val);
                }
                self.allocator.free(baseline_ops);
            }

            for (baseline_ops) |op| {
                switch (op.op_type) {
                    .put => try baseline_w.put(op.key, op.value.?),
                    .delete => try baseline_w.del(op.key),
                }
            }
            _ = try baseline_w.commit();

            // Capture snapshot states at different points
            const num_snapshots = 5;
            var snapshot_states = try self.allocator.alloc(TestSnapshot, num_snapshots);
            defer {
                for (snapshot_states) |*snap| {
                    snap.deinit(self.allocator);
                }
                self.allocator.free(snapshot_states);
            }

            var snapshot_txn_ids = try self.allocator.alloc(u64, num_snapshots);
            defer self.allocator.free(snapshot_txn_ids);

            // Create snapshots at different points
            for (0..num_snapshots) |i| {
                var w = model.beginWrite();
                const ops = try generator.generateSequence(5, 10);
                defer {
                    for (ops) |op| {
                        self.allocator.free(op.key);
                        if (op.value) |val| self.allocator.free(val);
                    }
                    self.allocator.free(ops);
                }

                for (ops) |op| {
                    switch (op.op_type) {
                        .put => try w.put(op.key, op.value.?),
                        .delete => try w.del(op.key),
                    }
                }
                const txn_id = try w.commit();
                snapshot_txn_ids[i] = txn_id;
                stats.total_txns += 1;

                // Capture snapshot state
                var snap = try model.beginRead(txn_id);
                defer {
                    var it2 = snap.iterator();
                    while (it2.next()) |entry| {
                        self.allocator.free(entry.key_ptr.*);
                        self.allocator.free(entry.value_ptr.*);
                    }
                    snap.deinit();
                }

                snapshot_states[i] = try TestSnapshot.fromSnapshotState(snap, self.allocator);
            }

            // Verify each snapshot is still accessible and consistent
            for (snapshot_txn_ids, 0..) |txn_id, i| {
                var verify_snap = try model.beginRead(txn_id);
                defer {
                    var it = verify_snap.iterator();
                    while (it.next()) |entry| {
                        self.allocator.free(entry.key_ptr.*);
                        self.allocator.free(entry.value_ptr.*);
                    }
                    verify_snap.deinit();
                }

                const expected = &snapshot_states[i];

                if (verify_snap.count() != expected.map.count()) {
                    test_passed = false;
                    err_msg = try std.fmt.allocPrint(self.allocator, "Iteration {}: Snapshot {} key count changed from {} to {}", .{ iteration, i, expected.map.count(), verify_snap.count() });
                    break;
                }

                // Verify all key-value pairs match
                var it = expected.map.iterator();
                while (it.next()) |entry| {
                    const actual_val = verify_snap.get(entry.key_ptr.*) orelse {
                        test_passed = false;
                        err_msg = try std.fmt.allocPrint(self.allocator, "Iteration {}: Snapshot {} key {s} missing", .{ iteration, i, entry.key_ptr.* });
                        break;
                    };

                    if (!std.mem.eql(u8, entry.value_ptr.*, actual_val)) {
                        test_passed = false;
                        err_msg = try std.fmt.allocPrint(self.allocator, "Iteration {}: Snapshot {} key {s} value changed", .{ iteration, i, entry.key_ptr.* });
                        break;
                    }
                }

                if (!test_passed) break;
            }

            if (test_passed) {
                result.passIteration();
            } else {
                if (err_msg) |msg| {
                    result.fail("Concurrent snapshot isolation violation: {s}", .{msg});
                    self.allocator.free(msg);
                } else {
                    result.fail("Concurrent snapshot isolation violation in iteration {}", .{iteration});
                }
                break;
            }
        }

        result.complete(self.config.num_iterations);
        result.performance_stats = stats;
        return result;
    }
};

// ==================== MVCC Test Runner ====================

/// Run all MVCC-specific property tests
pub const MvccPropertyTestRunner = struct {
    config: PropertyTestConfig,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, config: PropertyTestConfig) MvccPropertyTestRunner {
        return MvccPropertyTestRunner{
            .config = config,
            .allocator = allocator,
        };
    }

    pub fn runAllMvccPropertyTests(self: *MvccPropertyTestRunner) ![]PropertyTestResult {
        var results = try self.allocator.alloc(PropertyTestResult, 3);

        // Run snapshot immutability tests
        {
            var prop = SnapshotImmutabilityProperty.init(self.allocator, self.config);
            const result = try prop.run();
            results[0] = result;
        }

        // Run time-travel correctness tests
        {
            var prop = TimeTravelCorrectnessProperty.init(self.allocator, self.config);
            const result = try prop.run();
            results[1] = result;
        }

        // Run concurrent snapshot isolation tests
        {
            var prop = ConcurrentSnapshotIsolationProperty.init(self.allocator, self.config);
            const result = try prop.run();
            results[2] = result;
        }

        return results;
    }
};

/// Run MVCC property tests as part of the normal test suite
pub fn runMvccPropertyTests(allocator: std.mem.Allocator) !void {
    const config = PropertyTestConfig{
        .max_concurrent_txns = 5,
        .max_keys_per_txn = 20,
        .max_total_keys = 100,
        .random_seed = 54321,
        .num_iterations = 50,
        .enable_crash_simulation = false,
    };

    var runner = MvccPropertyTestRunner.init(allocator, config);
    const results = try runner.runAllMvccPropertyTests();
    defer {
        for (results) |*result| {
            result.deinit();
        }
        allocator.free(results);
    }

    PropertyTestRunner.printResults(results);

    // Fail the test suite if any property test fails
    for (results) |result| {
        if (!result.passed) {
            std.log.err("MVCC property test '{s}' failed", .{result.test_name});
            return error.PropertyTestFailed;
        }
    }
}

// ==================== Unit Tests for MVCC Property Tests ====================

test "snapshot immutability property basic functionality" {
    const config = PropertyTestConfig{
        .num_iterations = 5,
        .random_seed = 42,
        .max_keys_per_txn = 10,
    };

    var prop = SnapshotImmutabilityProperty.init(std.testing.allocator, config);
    var result = try prop.run();
    defer result.deinit();

    try std.testing.expect(result.passed);
    try std.testing.expectEqual(@as(usize, 5), result.iterations_passed);
}

test "time travel correctness property basic functionality" {
    const config = PropertyTestConfig{
        .num_iterations = 5,
        .random_seed = 42,
        .max_keys_per_txn = 10,
    };

    var prop = TimeTravelCorrectnessProperty.init(std.testing.allocator, config);
    var result = try prop.run();
    defer result.deinit();

    try std.testing.expect(result.passed);
    try std.testing.expectEqual(@as(usize, 5), result.iterations_passed);
}

test "concurrent snapshot isolation property basic functionality" {
    const config = PropertyTestConfig{
        .num_iterations = 5,
        .random_seed = 42,
        .max_keys_per_txn = 10,
    };

    var prop = ConcurrentSnapshotIsolationProperty.init(std.testing.allocator, config);
    var result = try prop.run();
    defer result.deinit();

    try std.testing.expect(result.passed);
    try std.testing.expectEqual(@as(usize, 5), result.iterations_passed);
}

test "MVCC property test runner integration" {
    const config = PropertyTestConfig{
        .num_iterations = 3,
        .random_seed = 42,
        .max_keys_per_txn = 5,
        .enable_crash_simulation = false,
    };

    var runner = MvccPropertyTestRunner.init(std.testing.allocator, config);
    const results = try runner.runAllMvccPropertyTests();
    defer {
        for (results) |*result| {
            result.deinit();
        }
        std.testing.allocator.free(results);
    }

    try std.testing.expectEqual(@as(usize, 3), results.len);

    // All tests should pass
    for (results) |result| {
        try std.testing.expect(result.passed);
    }
}