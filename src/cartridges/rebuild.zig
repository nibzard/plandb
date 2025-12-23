//! Cartridge rebuild trigger system
//!
//! Monitors cartridges and automatically triggers rebuilds based on
//! invalidation policies, database state changes, and time-based triggers.

const std = @import("std");
const ArrayListManaged = std.array_list.Managed;
const format = @import("format.zig");

/// Rebuild trigger configuration
pub const RebuildConfig = struct {
    /// Check interval in milliseconds (how often to evaluate triggers)
    check_interval_ms: u64 = 60_000, // 1 minute default
    /// Enable automatic rebuilds
    auto_rebuild: bool = true,
    /// Maximum concurrent rebuilds
    max_concurrent_rebuilds: usize = 2,
    /// Minimum time between rebuilds for same cartridge (ms)
    rebuild_cooldown_ms: u64 = 300_000, // 5 minutes

    pub fn init() RebuildConfig {
        return RebuildConfig{};
    }
};

/// Rebuild trigger type
pub const TriggerType = enum {
    /// Transaction count threshold exceeded
    transaction_threshold,
    /// Age-based expiration
    age_expired,
    /// Explicit invalidation pattern matched
    pattern_matched,
    /// Manual/admin trigger
    manual,
    /// Database schema changed
    schema_change,
};

/// Rebuild reason details
pub const RebuildReason = struct {
    trigger_type: TriggerType,
    description: []const u8,
    current_value: u64,
    threshold_value: u64,

    pub fn format(reason: RebuildReason, allocator: std.mem.Allocator) ![]const u8 {
        return std.fmt.allocPrint(allocator, "{s}: {s} ({d} >= {d})", .{
            @tagName(reason.trigger_type),
            reason.description,
            reason.current_value,
            reason.threshold_value,
        });
    }
};

/// Rebuild task state
pub const RebuildState = enum(u8) {
    pending = 0,
    running = 1,
    completed = 2,
    failed = 3,
    cancelled = 4,
};

/// Single rebuild task
pub const RebuildTask = struct {
    cartridge_path: []const u8,
    cartridge_type: format.CartridgeType,
    state: RebuildState,
    reason: RebuildReason,
    created_at: i128,
    started_at: ?i128,
    completed_at: ?i128,
    error_message: ?[]const u8,
    new_cartridge_path: ?[]const u8,

    pub fn init(
        allocator: std.mem.Allocator,
        cartridge_path: []const u8,
        cartridge_type: format.CartridgeType,
        reason: RebuildReason
    ) !RebuildTask {
        return RebuildTask{
            .cartridge_path = try allocator.dupe(u8, cartridge_path),
            .cartridge_type = cartridge_type,
            .state = .pending,
            .reason = reason,
            .created_at = std.time.nanoTimestamp(),
            .started_at = null,
            .completed_at = null,
            .error_message = null,
            .new_cartridge_path = null,
        };
    }

    pub fn deinit(self: *RebuildTask, allocator: std.mem.Allocator) void {
        allocator.free(self.cartridge_path);
        if (self.error_message) |msg| allocator.free(msg);
        if (self.new_cartridge_path) |path| allocator.free(path);
    }

    pub fn markStarted(self: *RebuildTask) void {
        self.state = .running;
        self.started_at = std.time.nanoTimestamp();
    }

    pub fn markCompleted(self: *RebuildTask, new_path: []const u8, allocator: std.mem.Allocator) !void {
        self.state = .completed;
        self.completed_at = std.time.nanoTimestamp();
        self.new_cartridge_path = try allocator.dupe(u8, new_path);
    }

    pub fn markFailed(self: *RebuildTask, error_msg: []const u8, allocator: std.mem.Allocator) !void {
        self.state = .failed;
        self.completed_at = std.time.nanoTimestamp();
        self.error_message = try allocator.dupe(u8, error_msg);
    }

    pub fn durationMs(self: *const RebuildTask) ?u64 {
        if (self.started_at) |start| {
            const end = self.completed_at orelse std.time.nanoTimestamp();
            return @intCast(@divTrunc(end - start, 1_000_000));
        }
        return null;
    }
};

/// Rebuild trigger evaluator
pub const TriggerEvaluator = struct {
    allocator: std.mem.Allocator,
    config: RebuildConfig,
    last_check_time: i128,
    last_rebuild_times: std.StringHashMap(i128),

    pub fn init(allocator: std.mem.Allocator, config: RebuildConfig) TriggerEvaluator {
        return TriggerEvaluator{
            .allocator = allocator,
            .config = config,
            .last_check_time = 0,
            .last_rebuild_times = std.StringHashMap(i128).init(allocator),
        };
    }

    pub fn deinit(self: *TriggerEvaluator) void {
        var it = self.last_rebuild_times.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.last_rebuild_times.deinit();
    }

    /// Evaluate if a cartridge needs rebuild based on current state
    pub fn evaluateNeedsRebuild(
        self: *TriggerEvaluator,
        cartridge_path: []const u8,
        header: *const format.CartridgeHeader,
        metadata: *const format.CartridgeMetadata,
        current_txn_id: u64
    ) !?RebuildReason {
        const now = std.time.nanoTimestamp();

        // Check rebuild cooldown
        if (self.last_rebuild_times.get(cartridge_path)) |last_rebuild| {
            const elapsed_ms = @divTrunc(now - last_rebuild, 1_000_000);
            if (elapsed_ms < self.config.rebuild_cooldown_ms) {
                return null;
            }
        }

        // Check transaction count threshold
        const txn_delta = current_txn_id - header.source_txn_id;
        if (txn_delta >= metadata.invalidation_policy.max_new_txns) {
            return RebuildReason{
                .trigger_type = .transaction_threshold,
                .description = "Transaction count exceeded",
                .current_value = txn_delta,
                .threshold_value = metadata.invalidation_policy.max_new_txns,
            };
        }

        // Check age expiration
        const cartridge_age_ms = @divTrunc(now - @as(i128, @intCast(header.created_at * 1_000_000)), 1_000_000);
        const max_age_ms = metadata.invalidation_policy.max_age_seconds * 1000;
        if (max_age_ms > 0 and cartridge_age_ms >= @as(i128, @intCast(max_age_ms))) {
            return RebuildReason{
                .trigger_type = .age_expired,
                .description = "Cartridge age exceeded maximum",
                .current_value = @intCast(cartridge_age_ms),
                .threshold_value = max_age_ms,
            };
        }

        // Check minimum transaction threshold (incremental rebuild hint)
        if (txn_delta >= metadata.invalidation_policy.min_new_txns) {
            return RebuildReason{
                .trigger_type = .transaction_threshold,
                .description = "Minimum transactions for incremental rebuild",
                .current_value = txn_delta,
                .threshold_value = metadata.invalidation_policy.min_new_txns,
            };
        }

        return null;
    }

    /// Evaluate if a commit record should invalidate a cartridge
    pub fn evaluateCommitInvalidation(
        self: *TriggerEvaluator,
        commit_record: format.CommitRecord,
        header: *const format.CartridgeHeader,
        metadata: *const format.CartridgeMetadata,
        current_txn_id: u64
    ) bool {
        _ = self;

        // Use the invalidation policy to check
        return metadata.invalidation_policy.shouldInvalidate(
            commit_record,
            current_txn_id,
            header.source_txn_id
        );
    }

    /// Record that a rebuild was initiated
    pub fn recordRebuild(self: *TriggerEvaluator, cartridge_path: []const u8, allocator: std.mem.Allocator) !void {
        const path_copy = try allocator.dupe(u8, cartridge_path);
        errdefer allocator.free(path_copy);

        const now = std.time.nanoTimestamp();
        try self.last_rebuild_times.put(path_copy, now);
    }

    /// Check if evaluation should run based on check interval
    pub fn shouldRunEvaluation(self: *TriggerEvaluator) bool {
        const now = std.time.nanoTimestamp();
        const elapsed_ms = @divTrunc(now - self.last_check_time, 1_000_000);
        return elapsed_ms >= self.config.check_interval_ms;
    }

    /// Mark evaluation as run
    pub fn markEvaluationRun(self: *TriggerEvaluator) void {
        self.last_check_time = std.time.nanoTimestamp();
    }
};

/// Rebuild queue manager
pub const RebuildQueue = struct {
    allocator: std.mem.Allocator,
    pending_tasks: ArrayListManaged(*RebuildTask),
    active_tasks: ArrayListManaged(*RebuildTask),
    completed_tasks: ArrayListManaged(*RebuildTask),
    config: RebuildConfig,

    pub fn init(allocator: std.mem.Allocator, config: RebuildConfig) RebuildQueue {
        return RebuildQueue{
            .allocator = allocator,
            .pending_tasks = ArrayListManaged(*RebuildTask).init(allocator),
            .active_tasks = ArrayListManaged(*RebuildTask).init(allocator),
            .completed_tasks = ArrayListManaged(*RebuildTask).init(allocator),
            .config = config,
        };
    }

    pub fn deinit(self: *RebuildQueue) void {
        for (self.pending_tasks.items) |task| {
            task.deinit(self.allocator);
            self.allocator.destroy(task);
        }
        self.pending_tasks.deinit();

        for (self.active_tasks.items) |task| {
            task.deinit(self.allocator);
            self.allocator.destroy(task);
        }
        self.active_tasks.deinit();

        for (self.completed_tasks.items) |task| {
            task.deinit(self.allocator);
            self.allocator.destroy(task);
        }
        self.completed_tasks.deinit();
    }

    /// Add a rebuild task to the queue
    pub fn enqueue(self: *RebuildQueue, task: *RebuildTask) !void {
        try self.pending_tasks.append(task);
    }

    /// Get next pending task (null if none available or at concurrency limit)
    pub fn getNextTask(self: *RebuildQueue) ?*RebuildTask {
        if (self.active_tasks.items.len >= self.config.max_concurrent_rebuilds) {
            return null;
        }
        if (self.pending_tasks.items.len == 0) {
            return null;
        }
        const task = self.pending_tasks.orderedRemove(0);
        self.active_tasks.append(task) catch return null;
        return task;
    }

    /// Complete a task and move to completed list
    pub fn completeTask(self: *RebuildQueue, task: *RebuildTask) !void {
        // Remove from active
        var i: usize = 0;
        while (i < self.active_tasks.items.len) {
            if (self.active_tasks.items[i] == task) {
                _ = self.active_tasks.orderedRemove(i);
                break;
            }
            i += 1;
        }
        try self.completed_tasks.append(task);

        // Prune old completed tasks (keep last 100)
        const prune_count = if (self.completed_tasks.items.len > 100)
            self.completed_tasks.items.len - 100
        else
            0;
        i = 0;
        while (i < prune_count) : (i += 1) {
            const old_task = self.completed_tasks.orderedRemove(0);
            old_task.deinit(self.allocator);
            self.allocator.destroy(old_task);
        }
    }

    /// Get queue statistics
    pub fn getStats(self: *const RebuildQueue) QueueStats {
        return QueueStats{
            .pending_count = self.pending_tasks.items.len,
            .active_count = self.active_tasks.items.len,
            .completed_count = self.completed_tasks.items.len,
        };
    }

    /// Find task by cartridge path
    pub fn findTask(self: *RebuildQueue, cartridge_path: []const u8) ?*RebuildTask {
        for (self.pending_tasks.items) |task| {
            if (std.mem.eql(u8, task.cartridge_path, cartridge_path)) return task;
        }
        for (self.active_tasks.items) |task| {
            if (std.mem.eql(u8, task.cartridge_path, cartridge_path)) return task;
        }
        return null;
    }

    /// Cancel a pending task
    pub fn cancelTask(self: *RebuildQueue, cartridge_path: []const u8) bool {
        var i: usize = 0;
        while (i < self.pending_tasks.items.len) {
            const task = self.pending_tasks.items[i];
            if (std.mem.eql(u8, task.cartridge_path, cartridge_path)) {
                _ = self.pending_tasks.orderedRemove(i);
                task.state = .cancelled;
                task.completed_at = std.time.nanoTimestamp();
                self.completed_tasks.append(task) catch {};
                return true;
            }
            i += 1;
        }
        return false;
    }
};

/// Queue statistics
pub const QueueStats = struct {
    pending_count: usize,
    active_count: usize,
    completed_count: usize,
};

/// Rebuild executor
pub const RebuildExecutor = struct {
    allocator: std.mem.Allocator,
    queue: *RebuildQueue,
    evaluator: *TriggerEvaluator,
    active_executions: ArrayListManaged(ActiveExecution),

    const ActiveExecution = struct {
        task: *RebuildTask,
        start_time: i128,
    };

    pub fn init(
        allocator: std.mem.Allocator,
        queue: *RebuildQueue,
        evaluator: *TriggerEvaluator
    ) RebuildExecutor {
        return RebuildExecutor{
            .allocator = allocator,
            .queue = queue,
            .evaluator = evaluator,
            .active_executions = ArrayListManaged(ActiveExecution).init(allocator),
        };
    }

    pub fn deinit(self: *RebuildExecutor) void {
        self.active_executions.deinit();
    }

    /// Process pending rebuilds (executes next available task)
    pub fn processPending(self: *RebuildExecutor) !bool {
        const task = self.queue.getNextTask() orelse return false;

        // Mark as started
        task.markStarted();

        // Record rebuild time
        try self.evaluator.recordRebuild(task.cartridge_path, self.allocator);

        // Track execution
        try self.active_executions.append(.{
            .task = task,
            .start_time = std.time.nanoTimestamp(),
        });

        // Execute rebuild (placeholder - actual implementation would call cartridge builder)
        _ = try self.executeRebuild(task);

        return true;
    }

    fn executeRebuild(self: *RebuildExecutor, task: *RebuildTask) !void {
        // Placeholder: In real implementation, this would:
        // 1. Call the cartridge builder to rebuild
        // 2. Validate the new cartridge
        // 3. Replace the old cartridge
        // 4. Update task status

        _ = self;
        _ = task;

        // Simulate rebuild
        return error.NotImplemented;
    }

    /// Complete a rebuild task
    pub fn completeRebuild(
        self: *RebuildExecutor,
        task: *RebuildTask,
        new_cartridge_path: []const u8
    ) !void {
        try task.markCompleted(new_cartridge_path, self.allocator);
        try self.queue.completeTask(task);

        // Remove from active executions
        var i: usize = 0;
        while (i < self.active_executions.items.len) {
            if (self.active_executions.items[i].task == task) {
                _ = self.active_executions.orderedRemove(i);
                break;
            }
            i += 1;
        }
    }

    /// Fail a rebuild task
    pub fn failRebuild(
        self: *RebuildExecutor,
        task: *RebuildTask,
        error_msg: []const u8
    ) !void {
        try task.markFailed(error_msg, self.allocator);
        try self.queue.completeTask(task);

        // Remove from active executions
        var i: usize = 0;
        while (i < self.active_executions.items.len) {
            if (self.active_executions.items[i].task == task) {
                _ = self.active_executions.orderedRemove(i);
                break;
            }
            i += 1;
        }
    }
};

// ==================== Tests ====================

test "RebuildConfig init" {
    const config = RebuildConfig.init();
    try std.testing.expectEqual(@as(u64, 60_000), config.check_interval_ms);
    try std.testing.expect(config.auto_rebuild);
}

test "RebuildTask init and state transitions" {
    const reason = RebuildReason{
        .trigger_type = .manual,
        .description = "Manual rebuild",
        .current_value = 0,
        .threshold_value = 0,
    };

    var task = try RebuildTask.init(
        std.testing.allocator,
        "test.cartridge",
        .pending_tasks_by_type,
        reason
    );
    defer task.deinit(std.testing.allocator);

    try std.testing.expectEqual(RebuildState.pending, task.state);
    try std.testing.expect(task.started_at == null);
    try std.testing.expect(task.completed_at == null);

    task.markStarted();
    try std.testing.expectEqual(RebuildState.running, task.state);
    try std.testing.expect(task.started_at != null);

    try task.markCompleted("new.cartridge", std.testing.allocator);
    try std.testing.expectEqual(RebuildState.completed, task.state);
    try std.testing.expect(task.completed_at != null);
    try std.testing.expectEqualStrings("new.cartridge", task.new_cartridge_path.?);
}

test "RebuildTask durationMs" {
    const reason = RebuildReason{
        .trigger_type = .manual,
        .description = "Test",
        .current_value = 0,
        .threshold_value = 0,
    };

    var task = try RebuildTask.init(
        std.testing.allocator,
        "test.cartridge",
        .pending_tasks_by_type,
        reason
    );
    defer task.deinit(std.testing.allocator);

    try std.testing.expect(task.durationMs() == null);

    task.markStarted();
    // Busy wait to ensure some time passes
    var i: usize = 0;
    while (i < 1000) : (i += 1) {
        _ = i * i;
    }
    const duration = task.durationMs();
    try std.testing.expect(duration != null);
    try std.testing.expect(duration.? >= 0);
}

test "TriggerEvaluator evaluateNeedsRebuild transaction threshold" {
    var evaluator = TriggerEvaluator.init(std.testing.allocator, .{});
    defer evaluator.deinit();

    var header = format.CartridgeHeader.init(.pending_tasks_by_type, 100);
    var metadata = format.CartridgeMetadata.init("test", std.testing.allocator);
    defer metadata.deinit(std.testing.allocator);

    metadata.invalidation_policy.max_new_txns = 50;

    const reason = try evaluator.evaluateNeedsRebuild(
        "test.cartridge",
        &header,
        &metadata,
        200 // current_txn_id
    );

    try std.testing.expect(reason != null);
    try std.testing.expectEqual(TriggerType.transaction_threshold, reason.?.trigger_type);
}

test "TriggerEvaluator evaluateNeedsRebuild cooldown" {
    var evaluator = TriggerEvaluator.init(std.testing.allocator, .{
        .rebuild_cooldown_ms = 1000, // 1 second
    });
    defer evaluator.deinit();

    // Record recent rebuild
    try evaluator.recordRebuild("test.cartridge", std.testing.allocator);

    var header = format.CartridgeHeader.init(.pending_tasks_by_type, 100);
    var metadata = format.CartridgeMetadata.init("test", std.testing.allocator);
    defer metadata.deinit(std.testing.allocator);

    metadata.invalidation_policy.max_new_txns = 50;

    // Should be blocked by cooldown
    const reason = try evaluator.evaluateNeedsRebuild(
        "test.cartridge",
        &header,
        &metadata,
        200
    );

    try std.testing.expect(reason == null);
}

test "TriggerEvaluator shouldRunEvaluation" {
    var evaluator = TriggerEvaluator.init(std.testing.allocator, .{
        .check_interval_ms = 100,
    });
    defer evaluator.deinit();

    try std.testing.expect(evaluator.shouldRunEvaluation());
    evaluator.markEvaluationRun();
    try std.testing.expect(!evaluator.shouldRunEvaluation());
}

test "RebuildQueue enqueue and getNextTask" {
    var queue = RebuildQueue.init(std.testing.allocator, .{
        .max_concurrent_rebuilds = 2,
    });
    defer queue.deinit();

    const reason = RebuildReason{
        .trigger_type = .manual,
        .description = "Test",
        .current_value = 0,
        .threshold_value = 0,
    };

    const task1 = try std.testing.allocator.create(RebuildTask);
    task1.* = try RebuildTask.init(std.testing.allocator, "test1.cartridge", .pending_tasks_by_type, reason);
    try queue.enqueue(task1);

    const task2 = try std.testing.allocator.create(RebuildTask);
    task2.* = try RebuildTask.init(std.testing.allocator, "test2.cartridge", .pending_tasks_by_type, reason);
    try queue.enqueue(task2);

    const stats = queue.getStats();
    try std.testing.expectEqual(@as(usize, 2), stats.pending_count);

    // Get first task
    const next = queue.getNextTask();
    try std.testing.expect(next != null);
    try std.testing.expectEqual(@as(usize, 1), queue.active_tasks.items.len);

    // Complete task
    try queue.completeTask(next.?);
    try std.testing.expectEqual(@as(usize, 0), queue.active_tasks.items.len);
    try std.testing.expectEqual(@as(usize, 1), queue.completed_tasks.items.len);
}

test "RebuildQueue cancelTask" {
    var queue = RebuildQueue.init(std.testing.allocator, .{});
    defer queue.deinit();

    const reason = RebuildReason{
        .trigger_type = .manual,
        .description = "Test",
        .current_value = 0,
        .threshold_value = 0,
    };

    const task = try std.testing.allocator.create(RebuildTask);
    task.* = try RebuildTask.init(std.testing.allocator, "test.cartridge", .pending_tasks_by_type, reason);
    try queue.enqueue(task);

    try std.testing.expect(queue.cancelTask("test.cartridge"));
    try std.testing.expect(!queue.cancelTask("test.cartridge")); // Already cancelled
    try std.testing.expectEqual(@as(usize, 0), queue.pending_tasks.items.len);
}

test "RebuildQueue findTask" {
    var queue = RebuildQueue.init(std.testing.allocator, .{});
    defer queue.deinit();

    const reason = RebuildReason{
        .trigger_type = .manual,
        .description = "Test",
        .current_value = 0,
        .threshold_value = 0,
    };

    const task = try std.testing.allocator.create(RebuildTask);
    task.* = try RebuildTask.init(std.testing.allocator, "test.cartridge", .pending_tasks_by_type, reason);
    try queue.enqueue(task);

    const found = queue.findTask("test.cartridge");
    try std.testing.expect(found != null);
    try std.testing.expect(found == task);

    const not_found = queue.findTask("other.cartridge");
    try std.testing.expect(not_found == null);
}

test "RebuildExecutor init" {
    var evaluator = TriggerEvaluator.init(std.testing.allocator, .{});
    defer evaluator.deinit();

    var queue = RebuildQueue.init(std.testing.allocator, .{});
    defer queue.deinit();

    var executor = RebuildExecutor.init(std.testing.allocator, &queue, &evaluator);
    defer executor.deinit();

    try std.testing.expectEqual(@as(usize, 0), executor.active_executions.items.len);
}
