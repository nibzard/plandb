//! Self-optimizing cartridge building and maintenance
//!
//! Automatically builds, updates, and maintains cartridges based on detected
//! usage patterns for optimal database performance.

const std = @import("std");
const mem = std.mem;

const PatternDetector = @import("patterns.zig").PatternDetector;
const Recommendation = @import("patterns.zig").Recommendation;
const EntityId = @import("../cartridges/structured_memory.zig").EntityId;
const CartridgeType = @import("../cartridges/format.zig").CartridgeType;

/// Autonomous cartridge builder
pub const CartridgeBuilder = struct {
    allocator: std.mem.Allocator,
    pattern_detector: *PatternDetector,
    build_queue: std.ArrayList(BuildTask),
    active_builds: std.ArrayList(ActiveBuild),
    config: BuilderConfig,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, pattern_detector: *PatternDetector, config: BuilderConfig) Self {
        return CartridgeBuilder{
            .allocator = allocator,
            .pattern_detector = pattern_detector,
            .build_queue = std.array_list.Managed(BuildTask).init(allocator),
            .active_builds = std.array_list.Managed(ActiveBuild).init(allocator),
            .config = config,
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.build_queue.items) |*task| {
            task.deinit(self.allocator);
        }
        self.build_queue.deinit();

        for (self.active_builds.items) |*build| {
            build.deinit(self.allocator);
        }
        self.active_builds.deinit();
    }

    /// Analyze patterns and queue cartridge builds
    pub fn updateBuildQueue(self: *Self) !usize {
        const recommendations = try self.pattern_detector.getRecommendations();
        defer {
            for (recommendations) |*r| r.deinit(self.allocator);
            self.allocator.free(recommendations);
        }

        var queued: usize = 0;

        for (recommendations) |rec| {
            if (rec.type == .build_cartridge or rec.type == .add_cache) {
                const task = BuildTask{
                    .cartridge_type = self.inferCartridgeType(rec.target),
                    .target = try self.allocator.dupe(u8, rec.target),
                    .priority = rec.priority,
                    .reason = try self.allocator.dupe(u8, rec.description),
                    .state = .pending,
                };

                // Check if already queued
                var already_queued = false;
                for (self.build_queue.items) |existing| {
                    if (mem.eql(u8, existing.target, task.target)) {
                        already_queued = true;
                        break;
                    }
                }

                if (!already_queued) {
                    try self.build_queue.append(task);
                    queued += 1;
                }
            }
        }

        // Sort queue by priority
        std.sort.insertion(BuildTask, self.build_queue.items, {}, struct {
            fn lessThan(_: void, a: BuildTask, b: BuildTask) bool {
                return a.priority > b.priority;
            }
        }.lessThan);

        return queued;
    }

    /// Execute pending builds
    pub fn executeBuilds(self: *Self, limit: usize) !BuildResult {
        var completed: usize = 0;
        var failed: usize = 0;
        var skipped: usize = 0;

        var i: usize = 0;
        while (i < self.build_queue.items.len and completed + failed < limit) : (i += 1) {
            var task = self.build_queue.orderedRemove(i);

            // Skip if concurrency limit reached
            if (self.active_builds.items.len >= self.config.max_concurrent_builds) {
                try self.build_queue.insert(i, task);
                skipped += 1;
                continue;
            }

            // Execute build
            task.state = .building;

            const build_result = self.buildCartridge(&task) catch |err| {
                std.log.warn("Cartridge build failed for {s}: {}", .{task.target, err});
                task.state = .failed;
                failed += 1;
                task.deinit(self.allocator);
                continue;
            };

            completed += 1;
            task.state = .completed;

            // Track active build for monitoring
            try self.active_builds.append(ActiveBuild{
                .target = try self.allocator.dupe(u8, task.target),
                .start_time = std.time.nanoTimestamp(),
                .cartridge_path = build_result.cartridge_path,
            });

            task.deinit(self.allocator);
        }

        // Clean up completed builds
        var j: usize = 0;
        while (j < self.active_builds.items.len) {
            const build = &self.active_builds.items[j];
            const elapsed_ms = (std.time.nanoTimestamp() - build.start_time) / 1_000_000;

            if (elapsed_ms > 5_000) { // 5 seconds
                build.deinit(self.allocator);
                _ = self.active_builds.orderedRemove(j);
            } else {
                j += 1;
            }
        }

        return BuildResult{
            .completed = completed,
            .failed = failed,
            .skipped = skipped,
            .remaining = self.build_queue.items.len,
        };
    }

    /// Check if cartridge needs rebuild
    pub fn checkNeedsRebuild(self: *Self, cartridge_path: []const u8) !bool {
        _ = cartridge_path;

        // Check against invalidation patterns
        // In real implementation, would load cartridge metadata and check
        return false;
    }

    /// Schedule automatic rebuild
    pub fn scheduleRebuild(self: *Self, cartridge_path: []const u8, reason: []const u8) !void {
        const task = BuildTask{
            .cartridge_type = .entity_index, // Would detect from path
            .target = try self.allocator.dupe(u8, cartridge_path),
            .priority = 5, // Medium priority for rebuilds
            .reason = try self.allocator.dupe(u8, reason),
            .state = .pending,
        };

        try self.build_queue.append(task);
    }

    fn inferCartridgeType(self: *Self, target: []const u8) CartridgeType {
        _ = self;
        _ = target;
        // In real implementation, would infer from pattern
        return .entity_index;
    }

    fn buildCartridge(self: *Self, task: *const BuildTask) !BuildSuccess {
        _ = self;
        _ = task;

        // In real implementation, would:
        // 1. Scan database for matching entities
        // 2. Build cartridge file
        // 3. Compute checksums
        // 4. Register cartridge

        const cartridge_path = try std.fmt.allocPrint(
            self.allocator,
            "cartridges/{s}.ncar",
            .{task.target}
        );

        return BuildSuccess{
            .cartridge_path = cartridge_path,
            .entity_count = 0,
            .build_time_ms = 0,
        };
    }
};

/// Build task
pub const BuildTask = struct {
    cartridge_type: CartridgeType,
    target: []const u8,
    priority: u8,
    reason: []const u8,
    state: BuildState,

    pub fn deinit(self: *BuildTask, allocator: std.mem.Allocator) void {
        allocator.free(self.target);
        allocator.free(self.reason);
    }

    pub const BuildState = enum {
        pending,
        building,
        completed,
        failed,
    };
};

/// Active build being monitored
pub const ActiveBuild = struct {
    target: []const u8,
    start_time: i128,
    cartridge_path: []const u8,

    pub fn deinit(self: *ActiveBuild, allocator: std.mem.Allocator) void {
        allocator.free(self.target);
        allocator.free(self.cartridge_path);
    }
};

/// Build result
pub const BuildResult = struct {
    completed: usize,
    failed: usize,
    skipped: usize,
    remaining: usize,
};

/// Build success details
pub const BuildSuccess = struct {
    cartridge_path: []const u8,
    entity_count: usize,
    build_time_ms: u64,
};

/// Builder configuration
pub const BuilderConfig = struct {
    max_concurrent_builds: usize = 3,
    max_queue_size: usize = 100,
    build_timeout_ms: u64 = 300_000, // 5 minutes
    min_priority_threshold: u8 = 3,
};

/// Cartridge maintainer
pub const CartridgeMaintainer = struct {
    allocator: std.mem.Allocator,
    builder: *CartridgeBuilder,
    maintenance_schedule: std.ArrayList(ScheduledTask),
    stats: MaintenanceStats,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, builder: *CartridgeBuilder) Self {
        return CartridgeMaintainer{
            .allocator = allocator,
            .builder = builder,
            .maintenance_schedule = std.array_list.Managed(ScheduledTask).init(allocator),
            .stats = MaintenanceStats{},
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.maintenance_schedule.items) |*task| {
            task.deinit(self.allocator);
        }
        self.maintenance_schedule.deinit();
    }

    /// Run maintenance cycle
    pub fn runMaintenanceCycle(self: *Self) !MaintenanceResult {
        var updated: usize = 0;
        var rebuilt: usize = 0;
        var archived: usize = 0;

        // Update build queue from patterns
        const queued = try self.builder.updateBuildQueue();
        updated = queued;

        // Execute builds
        const build_result = try self.builder.executeBuilds(10);
        rebuilt = build_result.completed;
        _ = build_result.failed;

        // Process scheduled tasks
        var i: usize = 0;
        while (i < self.maintenance_schedule.items.len) {
            const task = &self.maintenance_schedule.items[i];

            if (task.isDue()) {
                const result = try self.executeTask(task);
                _ = result;

                if (task.recurring) {
                    task.last_run = std.time.nanoTimestamp();
                } else {
                    task.deinit(self.allocator);
                    _ = self.maintenance_schedule.orderedRemove(i);
                    continue;
                }
            }

            i += 1;
        }

        self.stats.total_maintenance_cycles += 1;
        self.stats.cartridges_built += rebuilt;
        self.stats.cartridges_archived += archived;

        return MaintenanceResult{
            .builds_queued = updated,
            .cartridges_built = rebuilt,
            .cartridges_archived = archived,
        };
    }

    /// Schedule a maintenance task
    pub fn scheduleTask(self: *Self, task: ScheduledTask) !void {
        try self.maintenance_schedule.append(task);
    }

    fn executeTask(self: *Self, task: *const ScheduledTask) !TaskResult {
        _ = self;

        return switch (task.task_type) {
            .rebuild_all => TaskResult{ .rebuilt_count = 0 },
            .compact_all => TaskResult{ .compacted_count = 0 },
            .archive_old => TaskResult{ .archived_count = 0 },
            .optimize_indexes => TaskResult{ .optimized_count = 0 },
        };
    }
};

/// Scheduled maintenance task
pub const ScheduledTask = struct {
    name: []const u8,
    task_type: TaskType,
    interval_ms: u64,
    last_run: i128,
    recurring: bool,

    pub fn deinit(self: *ScheduledTask, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
    }

    pub fn isDue(self: *const ScheduledTask) bool {
        if (self.last_run == 0) return true;

        const now = std.time.nanoTimestamp();
        const elapsed_ms = (now - self.last_run) / 1_000_000;

        return elapsed_ms >= self.interval_ms;
    }

    pub const TaskType = enum {
        rebuild_all,
        compact_all,
        archive_old,
        optimize_indexes,
    };
};

/// Maintenance result
pub const MaintenanceResult = struct {
    builds_queued: usize,
    cartridges_built: usize,
    cartridges_archived: usize,
};

/// Task execution result
pub const TaskResult = struct {
    rebuilt_count: usize,
    compacted_count: usize,
    archived_count: usize,
    optimized_count: usize,
};

/// Maintenance statistics
pub const MaintenanceStats = struct {
    total_maintenance_cycles: u64 = 0,
    cartridges_built: u64 = 0,
    cartridges_archived: u64 = 0,
    cartridges_optimized: u64 = 0,
};

/// Autonomous cartridge manager
pub const AutonomousCartridgeManager = struct {
    allocator: std.mem.Allocator,
    builder: CartridgeBuilder,
    maintainer: CartridgeMaintainer,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, pattern_detector: *PatternDetector) Self {
        var builder = CartridgeBuilder.init(allocator, pattern_detector, BuilderConfig{});
        var maintainer = CartridgeMaintainer.init(allocator, &builder);

        return AutonomousCartridgeManager{
            .allocator = allocator,
            .builder = builder,
            .maintainer = maintainer,
        };
    }

    pub fn deinit(self: *Self) void {
        self.builder.deinit();
        self.maintainer.deinit();
    }

    /// Run autonomous optimization cycle
    pub fn runOptimizationCycle(self: *Self) !OptimizationResult {
        // Update build queue
        const queued = try self.builder.updateBuildQueue();

        // Execute builds
        const build_result = try self.builder.executeBuilds(5);

        // Run maintenance
        const maint_result = try self.maintainer.runMaintenanceCycle();

        return OptimizationResult{
            .builds_queued = queued,
            .builds_completed = build_result.completed,
            .builds_failed = build_result.failed,
            .maintenance_completed = maint_result.cartridges_built,
        };
    }

    /// Get manager status
    pub fn getStatus(self: *const Self) ManagerStatus {
        return ManagerStatus{
            .pending_builds = self.builder.build_queue.items.len,
            .active_builds = self.builder.active_builds.items.len,
            .scheduled_tasks = self.maintainer.maintenance_schedule.items.len,
            .maintenance_cycles = self.maintainer.stats.total_maintenance_cycles,
        };
    }
};

/// Optimization cycle result
pub const OptimizationResult = struct {
    builds_queued: usize,
    builds_completed: usize,
    builds_failed: usize,
    maintenance_completed: usize,
};

/// Manager status
pub const ManagerStatus = struct {
    pending_builds: usize,
    active_builds: usize,
    scheduled_tasks: usize,
    maintenance_cycles: u64,
};

// ==================== Tests ====================//

test "CartridgeBuilder init" {
    var detector = PatternDetector.init(std.testing.allocator, .{});
    defer detector.deinit();

    var builder = CartridgeBuilder.init(std.testing.allocator, &detector, .{});
    defer builder.deinit();

    try std.testing.expectEqual(@as(usize, 0), builder.build_queue.items.len);
}

test "CartridgeBuilder updateBuildQueue" {
    var detector = PatternDetector.init(std.testing.allocator, .{
        .min_queries_for_recommendations = 0,
    });
    defer detector.deinit();

    // Add some pattern data
    var i: u64 = 0;
    while (i < 10) : (i += 1) {
        try detector.recordEntityAccess("hot:entity", .read);
    }

    var builder = CartridgeBuilder.init(std.testing.allocator, &detector, .{});
    defer builder.deinit();

    const queued = try builder.updateBuildQueue();

    try std.testing.expect(queued > 0);
}

test "CartridgeBuilder executeBuilds" {
    var detector = PatternDetector.init(std.testing.allocator, .{});
    defer detector.deinit();

    var builder = CartridgeBuilder.init(std.testing.allocator, &detector, .{});
    defer builder.deinit();

    const result = try builder.executeBuilds(5);

    try std.testing.expectEqual(@as(usize, 0), result.completed);
}

test "CartridgeMaintainer init" {
    var detector = PatternDetector.init(std.testing.allocator, .{});
    defer detector.deinit();

    var builder = CartridgeBuilder.init(std.testing.allocator, &detector, .{});
    var maintainer = CartridgeMaintainer.init(std.testing.allocator, &builder);
    defer maintainer.deinit();

    try std.testing.expectEqual(@as(usize, 0), maintainer.maintenance_schedule.items.len);
}

test "CartridgeMaintainer runMaintenanceCycle" {
    var detector = PatternDetector.init(std.testing.allocator, .{});
    defer detector.deinit();

    var builder = CartridgeBuilder.init(std.testing.allocator, &detector, .{});
    var maintainer = CartridgeMaintainer.init(std.testing.allocator, &builder);
    defer maintainer.deinit();

    const result = try maintainer.runMaintenanceCycle();

    _ = result;
    // Should complete without error
}

test "ScheduledTask isDue" {
    const task = ScheduledTask{
        .name = "test",
        .task_type = .rebuild_all,
        .interval_ms = 1000,
        .last_run = 0,
        .recurring = true,
    };

    try std.testing.expect(task.isDue());
}

test "AutonomousCartridgeManager init" {
    var detector = PatternDetector.init(std.testing.allocator, .{});
    defer detector.deinit();

    var manager = AutonomousCartridgeManager.init(std.testing.allocator, &detector);
    defer manager.deinit();

    const status = manager.getStatus();

    try std.testing.expectEqual(@as(usize, 0), status.pending_builds);
}

test "BuildTask deinit" {
    var task = BuildTask{
        .cartridge_type = .entity_index,
        .target = try std.testing.allocator.dupe(u8, "test"),
        .priority = 5,
        .reason = try std.testing.allocator.dupe(u8, "test reason"),
        .state = .pending,
    };

    task.deinit(std.testing.allocator);

    // If we get here, deinit worked
    try std.testing.expect(true);
}
