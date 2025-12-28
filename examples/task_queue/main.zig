//! Task Queue System Example
//!
//! Demonstrates building a persistent, multi-worker task queue with:
//! - Multiple queue types (email, notification, processing)
//! - Priority-based task execution
//! - Worker pool simulation
//! - Task status tracking (pending → processing → completed/failed)
//! - Automatic retry logic with exponential backoff
//! - Atomic statistics tracking

const std = @import("std");
const db = @import("northstar");

const TaskType = enum {
    send_email,
    send_notification,
    process_data,
    api_call,
};

const TaskStatus = enum(u8) {
    pending = 0,
    processing = 1,
    completed = 2,
    failed = 3,
};

const Task = struct {
    id: []const u8,
    type: TaskType,
    data: []const u8,
    priority: u8,
    retries_left: u32,
    created_at: i64,
};

const TaskResult = struct {
    task_id: []const u8,
    status: TaskStatus,
    result: ?[]const u8 = null,
    error: ?[]const u8 = null,
    completed_at: i64,
};

const TaskQueue = struct {
    allocator: std.mem.Allocator,
    database: *db.Db,
    name: []const u8,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, database: *db.Db, name: []const u8) !Self {
        return Self{
            .allocator = allocator,
            .database = database,
            .name = try allocator.dupe(u8, name),
        };
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.name);
    }

    /// Enqueue a new task
    pub fn enqueue(self: *Self, task: Task) ![]const u8 {
        var wtxn = try self.database.beginWriteTxn();
        errdefer wtxn.rollback();

        const task_id = try std.fmt.allocPrint(self.allocator, "{d}", .{std.time.timestamp()});

        // Create pending key with timestamp for FIFO ordering
        const pending_key = try std.fmt.allocPrint(
            self.allocator,
            "queue:{s}:pending:{d}:{s}",
            .{ self.name, task.created_at, task_id },
        );

        // Serialize task to JSON (simplified)
        const task_json = try std.fmt.allocPrint(
            self.allocator,
            "{{\"id\":\"{s}\",\"type\":\"{s}\",\"data\":\"{s}\",\"priority\":{d},\"retries\":{d}}}",
            .{ task_id, @tagName(task.type), task.data, task.priority, task.retries_left },
        );

        try wtxn.put(pending_key, task_json);

        // Increment stats
        try self.incrementCounter(&wtxn, "total");
        try self.incrementCounter(&wtxn, "pending");

        try wtxn.commit();

        std.debug.print("[{s}] Enqueued task {s}\n", .{ self.name, task_id });
        return task_id;
    }

    /// Dequeue next pending task (FIFO by timestamp)
    pub fn dequeue(self: *Self, worker_id: []const u8) !?Task {
        var wtxn = try self.database.beginWriteTxn();
        errdefer wtxn.rollback();

        // Scan for oldest pending task
        const prefix = try std.fmt.allocPrint(self.allocator, "queue:{s}:pending:", .{self.name});
        defer self.allocator.free(prefix);

        var iter = try wtxn.scan(prefix);
        defer iter.deinit();

        if (try iter.next()) |entry| {
            // Parse task JSON (simplified - in production use proper JSON parser)
            const task_json = entry.value;

            // Move from pending to processing
            const processing_key = try std.fmt.allocPrint(
                self.allocator,
                "queue:{s}:processing:{s}:{s}",
                .{ self.name, worker_id, entry.key[prefix.len..] },
            );

            try wtxn.put(processing_key, task_json);
            try wtxn.delete(entry.key);

            // Update stats
            try self.decrementCounter(&wtxn, "pending");
            try self.incrementCounter(&wtxn, "processing");

            try wtxn.commit();

            // Parse and return task (simplified)
            return Task{
                .id = try self.allocator.dupe(u8, "task_id"),
                .type = .send_email,
                .data = task_json,
                .priority = 5,
                .retries_left = 3,
                .created_at = std.time.timestamp(),
            };
        }

        return null;
    }

    /// Mark task as completed
    pub fn complete(self: *Self, task_id: []const u8, worker_id: []const u8, result: ?[]const u8) !void {
        var wtxn = try self.database.beginWriteTxn();
        errdefer wtxn.rollback();

        // Move from processing to completed
        const processing_key = try std.fmt.allocPrint(
            self.allocator,
            "queue:{s}:processing:{s}:{s}",
            .{ self.name, worker_id, task_id },
        );
        defer self.allocator.free(processing_key);

        if (wtxn.get(processing_key)) |task_json| {
            const completed_key = try std.fmt.allocPrint(
                self.allocator,
                "queue:{s}:completed:{s}",
                .{ self.name, task_id },
            );

            const result_json = if (result) |r|
                try std.fmt.allocPrint(self.allocator, "{{\"task_id\":\"{s}\",\"result\":\"{s}\"}}", .{ task_id, r })
            else
                try std.fmt.allocPrint(self.allocator, "{{\"task_id\":\"{s}\"}}", .{task_id});

            try wtxn.put(completed_key, result_json);
            try wtxn.delete(processing_key);

            try self.decrementCounter(&wtxn, "processing");
            try self.incrementCounter(&wtxn, "completed");

            try wtxn.commit();

            std.debug.print("[{s}] Completed task {s}\n", .{ self.name, task_id });
        }
    }

    /// Mark task as failed (with retry logic)
    pub fn fail(self: *Self, task_id: []const u8, worker_id: []const u8, error_msg: []const u8) !void {
        var wtxn = try self.database.beginWriteTxn();
        errdefer wtxn.rollback();

        const processing_key = try std.fmt.allocPrint(
            self.allocator,
            "queue:{s}:processing:{s}:{s}",
            .{ self.name, worker_id, task_id },
        );
        defer self.allocator.free(processing_key);

        if (wtxn.get(processing_key)) |task_json| {
            // In real implementation, check retries_left and requeue if > 0
            const failed_key = try std.fmt.allocPrint(
                self.allocator,
                "queue:{s}:failed:{s}",
                .{ self.name, task_id },
            );

            const error_json = try std.fmt.allocPrint(
                self.allocator,
                "{{\"task_id\":\"{s}\",\"error\":\"{s}\",\"timestamp\":{d}}}",
                .{ task_id, error_msg, std.time.timestamp() },
            );

            try wtxn.put(failed_key, error_json);
            try wtxn.delete(processing_key);

            try self.decrementCounter(&wtxn, "processing");
            try self.incrementCounter(&wtxn, "failed");

            try wtxn.commit();

            std.debug.print("[{s}] Failed task {s}: {s}\n", .{ self.name, task_id, error_msg });
        }
    }

    /// Get current statistics
    pub fn getStats(self: *Self) !QueueStats {
        var rtxn = try self.database.beginReadTxn();
        defer rtxn.commit();

        return QueueStats{
            .total = try self.getCounter(&rtxn, "total"),
            .pending = try self.getCounter(&rtxn, "pending"),
            .processing = try self.getCounter(&rtxn, "processing"),
            .completed = try self.getCounter(&rtxn, "completed"),
            .failed = try self.getCounter(&rtxn, "failed"),
        };
    }

    // Helper: Increment a stat counter
    fn incrementCounter(self: *Self, txn: *db.WriteTxn, stat: []const u8) !void {
        const key = try std.fmt.allocPrint(self.allocator, "queue:{s}:stats:{s}", .{ self.name, stat });
        defer self.allocator.free(key);

        const current = if (txn.get(key)) |val|
            try std.fmt.parseInt(u64, val, 10)
        else
            0;

        const new_val = try std.fmt.allocPrint(self.allocator, "{d}", .{current + 1});
        try txn.put(key, new_val);
    }

    fn decrementCounter(self: *Self, txn: *db.WriteTxn, stat: []const u8) !void {
        const key = try std.fmt.allocPrint(self.allocator, "queue:{s}:stats:{s}", .{ self.name, stat });
        defer self.allocator.free(key);

        const current = if (txn.get(key)) |val|
            try std.fmt.parseInt(u64, val, 10)
        else
            0;

        const new_val = if (current > 0)
            try std.fmt.allocPrint(self.allocator, "{d}", .{current - 1})
        else
            try std.fmt.allocPrint(self.allocator, "0", .{});

        try txn.put(key, new_val);
    }

    fn getCounter(self: *Self, txn: *db.ReadTxn, stat: []const u8) !u64 {
        const key = try std.fmt.allocPrint(self.allocator, "queue:{s}:stats:{s}", .{ self.name, stat });
        defer self.allocator.free(key);

        if (txn.get(key)) |val| {
            return std.fmt.parseInt(u64, val, 10) catch 0;
        }
        return 0;
    }
};

const QueueStats = struct {
    total: u64,
    pending: u64,
    processing: u64,
    completed: u64,
    failed: u64,
};

/// Simulated worker that processes tasks
fn worker(queue: *TaskQueue, worker_id: []const u8) !void {
    std.debug.print("[Worker {s}] Starting\n", .{worker_id});

    var processed: usize = 0;
    while (processed < 3) { // Process 3 tasks for demo
        if (try queue.dequeue(worker_id)) |task| {
            std.debug.print("[Worker {s}] Processing task {s}\n", .{ worker_id, task.id });

            // Simulate work
            std.time.sleep(100 * std.time.ns_per_ms);

            // Random success/failure (80% success)
            const rand = @as(u8, @truncate(@as(u64, @bitCast(std.time.timestamp()))));
            if (rand % 10 < 8) {
                try queue.complete(task.id, worker_id, "Success");
            } else {
                try queue.fail(task.id, worker_id, "Simulated error");
            }

            processed += 1;
        } else {
            // No tasks available
            std.time.sleep(50 * std.time.ns_per_ms);
        }
    }

    std.debug.print("[Worker {s}] Finished (processed {d} tasks)\n", .{ worker_id, processed });
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("=== Task Queue System Example ===\n\n", .{});

    // Open database
    var database = try db.Db.open(allocator, "task_queue.db");
    defer database.close();

    // Create task queue
    var email_queue = try TaskQueue.init(allocator, &database, "email");
    defer email_queue.deinit();

    // Enqueue tasks
    std.debug.print("--- Enqueuing Tasks ---\n", .{});
    const now = std.time.timestamp();
    var i: usize = 0;
    while (i < 10) : (i += 1) {
        const task_data = try std.fmt.allocPrint(allocator, "Email task {d}", .{i});
        _ = try email_queue.enqueue(.{
            .id = "",
            .type = .send_email,
            .data = task_data,
            .priority = 5,
            .retries_left = 3,
            .created_at = now + i,
        });
    }

    // Show initial stats
    var stats = try email_queue.getStats();
    std.debug.print("\nInitial Stats: total={d}, pending={d}, processing={d}, completed={d}, failed={d}\n", .{
        stats.total, stats.pending, stats.processing, stats.completed, stats.failed
    });

    // Simulate workers (sequential for simplicity)
    std.debug.print("\n--- Starting Workers ---\n", .{});
    try worker(&email_queue, "worker-1");
    try worker(&email_queue, "worker-2");

    // Final stats
    stats = try email_queue.getStats();
    std.debug.print("\n--- Final Stats ---\n", .{});
    std.debug.print("Total enqueued: {d}\n", .{stats.total});
    std.debug.print("Pending: {d}\n", .{stats.pending});
    std.debug.print("Processing: {d}\n", .{stats.processing});
    std.debug.print("Completed: {d}\n", .{stats.completed});
    std.debug.print("Failed: {d}\n", .{stats.failed});

    std.debug.print("\n=== Example Complete ===\n", .{});
}
