# Task Queue System

A robust task queue implementation using NorthstarDB for persistent job management.

## Overview

This example demonstrates building a durable task queue with NorthstarDB, supporting:
- Multiple queue types (email, notifications, processing)
- Priority-based task execution
- Task status tracking (pending, processing, completed, failed)
- Worker pool simulation
- Automatic retry logic

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│                     Task Queue                           │
├─────────────────────────────────────────────────────────┤
│  Key Structure:                                         │
│  queue:<name>:pending:<timestamp>:<id>   → task JSON    │
│  queue:<name>:processing:<worker_id>:<id> → task JSON   │
│  queue:<name>:completed:<id>            → result JSON   │
│  queue:<name>:failed:<id>                → error JSON   │
├─────────────────────────────────────────────────────────┤
│  Metadata:                                              │
│  queue:<name>:stats:total          → counter           │
│  queue:<name>:stats:pending        → counter           │
│  queue:<name>:stats:processing     → counter           │
│  queue:<name>:stats:completed      → counter           │
│  queue:<name>:stats:failed         → counter           │
└─────────────────────────────────────────────────────────┘
```

## Usage

```zig
// Create a task queue
var queue = try TaskQueue.init(allocator, &database, "email");

// Enqueue tasks
const task_id = try queue.enqueue(.{
    .type = .send_email,
    .recipient = "user@example.com",
    .subject = "Welcome!",
    .body = "Thanks for signing up.",
});

// Start workers
try queue.startWorkers(4);

// Wait for completion
try queue.waitForCompletion();
```

## Running the Example

```bash
zig build-exe examples/task_queue/main.zig
./task_queue
```

## Features

### Task Types
- **Email Tasks**: Send notifications and alerts
- **Notification Tasks**: Push notifications for mobile/web
- **Processing Tasks**: Background data processing jobs

### Worker Behavior
- Each worker claims one task at a time
- Tasks are atomically moved from pending → processing
- Failed tasks are automatically retried with backoff
- Completed tasks are archived with results

### Persistence
- All tasks survive process restarts
- Processing tasks can be recovered on startup
- Stats are maintained atomically

## Performance Characteristics

- **Enqueue**: O(log n) - B+tree insertion
- **Dequeue**: O(log n) - Prefix scan + deletion
- **Complete**: O(log n) - Move to completed
- **Stats**: O(1) - Direct key access

## Scaling

For high-throughput scenarios:
1. Increase worker pool size
2. Use separate queues per priority level
3. Consider sharding by task type
4. Monitor queue depth and auto-scale

## Error Handling

```zig
// Tasks can fail with retry
queue.enqueue(.{
    .type = .api_call,
    .url = "https://api.example.com",
    .retries_left = 3,
    .backoff_ms = 1000,
});
```

Failed tasks increment the retry counter and can be re-queued automatically.
