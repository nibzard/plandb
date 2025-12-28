# Task Queue System

A robust task queue implementation using NorthstarDB for persistent job management.

## Overview

This example demonstrates building a durable task queue with NorthstarDB, supporting multiple queue types, priority-based execution, and comprehensive task tracking.

## Use Cases

- Background job processing (emails, notifications)
- Asynchronous task execution
- Work queue for distributed systems
- Cron job scheduling and execution
- Message queue alternative
- Batch processing pipelines

## Features Demonstrated

- **Multiple Queue Types**: Separate queues for different task categories
- **Priority-Based Execution**: Tasks ordered by timestamp/priority
- **Status Tracking**: pending → processing → completed/failed lifecycle
- **Worker Pool Simulation**: Multiple concurrent workers
- **Automatic Retry Logic**: Configurable retry with exponential backoff
- **Atomic Statistics**: Real-time queue metrics
- **Persistent Storage**: Survives process restarts

## Running the Example

```bash
cd examples/task_queue
zig build run

# Or build manually
zig build-exe main.zig
./task_queue
```

## Architecture Overview

```
┌─────────────────────────────────────────────────────────┐
│                     Task Queue                           │
├─────────────────────────────────────────────────────────┤
│  Key Structure:                                         │
│  queue:<name>:pending:<ts>:<id>    → task JSON         │
│  queue:<name>:processing:<worker>:<id> → task JSON     │
│  queue:<name>:completed:<id>       → result JSON       │
│  queue:<name>:failed:<id>          → error JSON        │
├─────────────────────────────────────────────────────────┤
│  Metadata:                                              │
│  queue:<name>:stats:total        → counter             │
│  queue:<name>:stats:pending      → counter             │
│  queue:<name>:stats:processing   → counter             │
│  queue:<name>:stats:completed    → counter             │
│  queue:<name>:stats:failed       → counter             │
└─────────────────────────────────────────────────────────┘
```

## Code Walkthrough

### 1. Queue Initialization

```zig
var queue = try TaskQueue.init(allocator, &database, "email");
defer queue.deinit();
```

**Key Points:**
- Each queue has a unique name (email, notifications, processing)
- Multiple queues can coexist in the same database
- Queue name is part of the key prefix for isolation

### 2. Task Enqueue

```zig
const task_id = try queue.enqueue(.{
    .id = "",
    .type = .send_email,
    .data = "Email task data",
    .priority = 5,
    .retries_left = 3,
    .created_at = std.time.timestamp(),
});
```

**Key Points:**
- Tasks are stored with timestamp for FIFO ordering
- Each task has a type for polymorphic handling
- Priority field for future priority queue support
- Retries left for automatic retry logic

### 3. Task Dequeue

```zig
if (try queue.dequeue("worker-1")) |task| {
    // Process task
    processTask(task);

    // Mark complete
    try queue.complete(task.id, "worker-1", "Success");
}
```

**Key Points:**
- Worker ID ensures only one worker processes a task
- Tasks moved atomically from pending → processing
- Returns null if no tasks available

### 4. Task Completion

```zig
try queue.complete(task_id, worker_id, optional_result);
```

**Key Points:**
- Moves task from processing → completed
- Stores optional result for auditing
- Updates statistics counters atomically

### 5. Error Handling

```zig
try queue.fail(task_id, worker_id, "Error message");
```

**Key Points:**
- Moves task from processing → failed
- Records error message and timestamp
- In production, would check retries and requeue

## Task Types

### Email Tasks
```zig
TaskType.send_email
// Data: {"to": "user@example.com", "subject": "...", "body": "..."}
```

### Notification Tasks
```zig
TaskType.send_notification
// Data: {"user_id": "123", "message": "...", "platform": "mobile"}
```

### Processing Tasks
```zig
TaskType.process_data
// Data: {"input_path": "/path/to/file", "output_path": "/out"}
```

### API Call Tasks
```zig
TaskType.api_call
// Data: {"url": "https://api.example.com", "method": "POST"}
```

## Worker Behavior

### Single Worker Pattern

```zig
fn worker(queue: *TaskQueue, worker_id: []const u8) !void {
    while (running) {
        // Try to get next task
        if (try queue.dequeue(worker_id)) |task| {
            // Process task
            const result = processTask(task);

            // Mark complete
            try queue.complete(task.id, worker_id, result);
        } else {
            // No tasks, wait a bit
            std.time.sleep(100 * std.time.ns_per_ms);
        }
    }
}
```

### Worker Pool Pattern

```zig
// Start multiple workers
var workers: [4]std.Thread = undefined;
var i: usize = 0;
while (i < 4) : (i += 1) {
    const worker_id = try std.fmt.allocPrint(allocator, "worker-{d}", .{i});
    workers[i] = try std.Thread.spawn(.{}, worker, .{ &queue, worker_id });
}

// Wait for all workers
for (workers) |w| w.join();
```

**Benefits:**
- Parallel task processing
- Automatic load balancing
- Fault isolation (one worker crash doesn't affect others)

## Retry Logic

### Exponential Backoff

```zig
fn shouldRetry(task: Task) bool {
    if (task.retries_left == 0) return false;

    // Calculate backoff: 2^retry * base_delay
    const backoff_ms = std.time.ms_per_s * (@as(u64, 1) << @truncate(3 - task.retries_left));
    std.time.sleep(backoff_ms * std.time.ns_per_ms);

    return true;
}
```

### Retry with Dead Letter Queue

```zig
fn failWithRetry(queue: *TaskQueue, task: Task, error: []const u8) !void {
    if (task.retries_left > 0) {
        // Decrement retry count and re-enqueue
        var retry_task = task;
        retry_task.retries_left -= 1;
        _ = try queue.enqueue(retry_task);
    } else {
        // Move to dead letter queue
        try queue.moveToDeadLetter(task, error);
    }
}
```

## Performance Characteristics

| Operation | Complexity | Notes |
|-----------|------------|-------|
| Enqueue | O(log n) | B+tree insertion with timestamp key |
| Dequeue | O(log n) | Prefix scan + deletion |
| Complete | O(log n) | Move from processing to completed |
| Get Stats | O(k) | k = number of stat counters (5) |

### Throughput Optimization

1. **Batch Enqueue**
```zig
var wtxn = try database.beginWriteTxn();
for (tasks) |task| {
    try enqueueInTxn(&wtxn, task);
}
try wtxn.commit();
```

2. **Prefetch Strategy**
```zig
// Worker prefetches multiple tasks
var pending: [10]Task = undefined;
var count: usize = 0;

// Fill pending buffer
while (count < 10) {
    if (try queue.dequeue(worker_id)) |task| {
        pending[count] = task;
        count += 1;
    } else break;
}

// Process buffered tasks
for (pending[0..count]) |task| {
    processTask(task);
    try queue.complete(task.id, worker_id, null);
}
```

## Monitoring and Observability

### Queue Statistics

```zig
const stats = try queue.getStats();
std.debug.print("Total: {d}\n", .{stats.total});
std.debug.print("Pending: {d}\n", .{stats.pending});
std.debug.print("Processing: {d}\n", .{stats.processing});
std.debug.print("Completed: {d}\n", .{stats.completed});
std.debug.print("Failed: {d}\n", .{stats.failed});
```

### Worker Health

```zig
fn checkWorkerHealth(queue: *TaskQueue) !void {
    const stats = try queue.getStats();

    // Check for stuck tasks
    if (stats.processing > 100) {
        std.debug.print("Warning: High processing count\n", .{});
    }

    // Check failure rate
    const failure_rate = @as(f64, @floatFromInt(stats.failed)) /
                         @as(f64, @floatFromInt(stats.completed));
    if (failure_rate > 0.1) {
        std.debug.print("Warning: High failure rate: {d:.2}%\n", .{failure_rate * 100});
    }
}
```

### Per-Queue Metrics

```zig
// Create separate queues for different priorities
var high_priority = try TaskQueue.init(allocator, &database, "queue:high");
var normal_priority = try TaskQueue.init(allocator, &database, "queue:normal");
var low_priority = try TaskQueue.init(allocator, &database, "queue:low");

// Monitor each queue
const hp_stats = try high_priority.getStats();
const np_stats = try normal_priority.getStats();
const lp_stats = try low_priority.getStats();
```

## Advanced Patterns

### Priority Queue

```zig
// Use priority in key for ordering
const priority_key = try std.fmt.allocPrint(
    allocator,
    "queue:{s}:pending:{d:03}:{d}:{s}",
    .{ queue_name, 255 - task.priority, task.created_at, task_id }
);
```

### Delayed Tasks

```zig
fn enqueueDelayed(queue: *TaskQueue, task: Task, delay_ms: u64) !void {
    const execute_at = std.time.timestamp() + (delay_ms / 1000);

    var wtxn = try database.beginWriteTxn();
    errdefer wtxn.rollback();

    // Store in delayed queue
    const delayed_key = try std.fmt.allocPrint(
        allocator,
        "queue:{s}:delayed:{d}:{s}",
        .{ queue.name, execute_at, task.id }
    );
    try wtxn.put(delayed_key, taskToJson(task));

    try wtxn.commit();
}
```

### Task Dependencies

```zig
fn enqueueWithDeps(queue: *TaskQueue, task: Task, deps: []const []const u8) !void {
    var wtxn = try database.beginWriteTxn();
    errdefer wtxn.rollback();

    // Store task with dependencies
    const deps_key = try std.fmt.allocPrint(
        allocator,
        "queue:{s}:deps:{s}",
        .{ queue.name, task.id }
    );

    var deps_list = std.ArrayList([]const u8).init(allocator);
    try deps_list.appendSlice(deps);

    const deps_json = try std.json.stringify(deps_list.items, .{}, allocator);
    try wtxn.put(deps_key, deps_json);

    // Enqueue task (will be blocked until deps complete)
    _ = try queue.enqueue(task);

    try wtxn.commit();
}
```

## Scaling Considerations

### Vertical Scaling

1. **Increase Worker Count**
```zig
const num_workers = getCpuCount() * 2;
try queue.startWorkers(num_workers);
```

2. **Batch Processing**
```zig
// Process multiple tasks per transaction
const BATCH_SIZE = 100;
var i: usize = 0;
while (i < BATCH_SIZE) : (i += 1) {
    if (try queue.dequeue(worker_id)) |task| {
        try processTask(task);
    }
}
```

### Horizontal Scaling

1. **Queue Sharding**
```zig
// Shard by task type or hash
const shard_id = @mod(hash(task.id), num_shards);
const queue_name = try std.fmt.allocPrint(allocator, "queue:{d}", .{shard_id});
var queue = try TaskQueue.init(allocator, &database, queue_name);
```

2. **Database Partitioning**
```zig
// Separate databases for high-volume queues
var email_db = try db.Db.open(allocator, "email_queue.db");
var processing_db = try db.Db.open(allocator, "processing_queue.db");
```

## Testing

```zig
test "task enqueue and dequeue" {
    var queue = try TaskQueue.init(testing.allocator, &database, "test");

    // Enqueue task
    const task_id = try queue.enqueue(.{
        .id = "",
        .type = .send_email,
        .data = "test",
        .priority = 5,
        .retries_left = 3,
        .created_at = 0,
    });

    // Dequeue
    const task = try queue.dequeue("worker-test");
    try testing.expect(task != null);
    try testing.expectEqualStrings(task_id, task.?.id);
}

test "task statistics" {
    var queue = try TaskQueue.init(testing.allocator, &database, "test");

    // Enqueue tasks
    var i: usize = 0;
    while (i < 10) : (i += 1) {
        _ = try queue.enqueue(defaultTask());
    }

    const stats = try queue.getStats();
    try testing.expectEqual(@as(u64, 10), stats.total);
    try testing.expectEqual(@as(u64, 10), stats.pending);
}
```

## Production Considerations

### 1. Transaction Isolation

Use separate transactions for each task to avoid blocking:

```zig
// GOOD: One transaction per task
while (try queue.dequeue(worker_id)) |task| {
    var wtxn = try database.beginWriteTxn();
    errdefer wtxn.rollback();
    try processTaskInTxn(&wtxn, task);
    try wtxn.commit();
}

// AVOID: Long-running transaction
var wtxn = try database.beginWriteTxn();
while (try queue.dequeue(worker_id)) |task| {
    try processTaskInTxn(&wtxn, task);
}
try wtxn.commit(); // Holds lock too long
```

### 2. Error Recovery

Implement recovery for crashes:

```zig
fn recoverStuckTasks(queue: *TaskQueue) !void {
    // Find tasks stuck in processing
    var rtxn = try database.beginReadTxn();
    defer rtxn.commit();

    var iter = try rtxn.scan("queue:email:processing:");
    defer iter.deinit();

    var stuck: std.ArrayList([]const u8) = std.ArrayList([]const u8).init(allocator);

    while (try iter.next()) |entry| {
        // Check timestamp
        const age = std.time.timestamp() - getTaskTimestamp(entry);
        if (age > TIMEOUT_SECS) {
            try stuck.append(try allocator.dupe(u8, entry.key));
        }
    }

    // Re-enqueue stuck tasks
    for (stuck.items) |key| {
        try queue.reenqueueStuck(key);
    }
}
```

### 3. Monitoring

Add comprehensive logging:

```zig
fn workerWithLogging(queue: *TaskQueue, worker_id: []const u8) !void {
    var processed: usize = 0;
    var start_time = std.time.timestamp();

    while (try queue.dequeue(worker_id)) |task| {
        const task_start = std.time.nanoTimestamp();

        if (processTask(task)) {
            const elapsed = std.time.nanoTimestamp() - task_start;
            log.info("Worker {s} completed task {s} in {ns}us", .{
                worker_id, task.id, elapsed / 1000
            });
            try queue.complete(task.id, worker_id, null);
        } else |err| {
            log.err("Worker {s} failed task {s}: {}", .{worker_id, task.id, err});
            try queue.fail(task.id, worker_id, @errorName(err));
        }

        processed += 1;
        if (processed % 100 == 0) {
            const elapsed_total = std.time.timestamp() - start_time;
            const rate = @as(f64, @floatFromInt(processed)) /
                        @as(f64, @floatFromInt(elapsed_total));
            log.info("Worker {s} throughput: {d:.2} tasks/sec", .{worker_id, rate});
        }
    }
}
```

## Next Steps

- **document_repo**: For indexing patterns
- **time_series**: For high-volume write patterns
- **ai_knowledge_base**: For complex data modeling

## See Also

- [Transaction Semantics](../../docs/semantics_v0.md)
- [Performance Tuning Guide](../../docs/guides/performance.md)
