---
title: Corruption Recovery Guide
description: Learn how to detect, recover from, and prevent database corruption in NorthstarDB.
---

import { Card, Cards } from '@astrojs/starlight/components';

This guide helps you detect corruption, recover your data, and implement prevention strategies.

<Cards>
  <Card title="Detect" icon="search">
    Identify corruption using validation tools and checksums.
  </Card>
  <Card title="Recover" icon="refresh-cw">
    Restore data from backups, WAL, or salvage operations.
  </Card>
  <Card title="Prevent" icon="shield">
    Implement strategies to avoid corruption in production.
  </Card>
</Cards>

## Overview

NorthstarDB uses multiple layers of corruption detection and recovery:

- **Checksums**: CRC32C on every page header and payload
- **Atomic commits**: Dual meta pages (Meta A/Meta B) for crash-safe writes
- **WAL replay**: Recover committed transactions from write-ahead log
- **Validation tools**: `dbdump` utility for inspection and export

### Corruption Handling Policy

NorthstarDB follows these principles for corruption:

1. **Never silent**: All corruption returns explicit errors, never undefined behavior
2. **Fail fast**: Detect corruption early, return `error.Corrupt` immediately
3. **Graceful degradation**: Continue reading from valid pages when possible
4. **Recovery first**: Provide tools to salvage data before attempting repairs

## Detecting Corruption

### Using the dbdump Tool

The `dbdump` utility validates database integrity:

```bash
# Validate entire database
zig-out/bin/dbdump validate database.db

# Show detailed statistics
zig-out/bin/dbdump stats database.db

# Dump structure for inspection
zig-out/bin/dbdump dump database.db
```

**Validation output:**
```
[INFO] Validating database: database.db
[INFO] Meta validation: OK (txn_id=1234)
[INFO] Page count: 1024
[INFO] Tree validation: OK
[INFO] Validation complete: 0 errors, 0 warnings
[INFO] Result: PASSED
```

### Checksum Failures

NorthstarDB validates checksums on every page read:

```zig
// Opening database with checksum validation
var db = try db.Db.open(path, allocator) catch |err| switch (err) {
    error.ChecksumMismatch => {
        std.log.err("Checksum validation failed", .{});
        // Use validation tools to locate corruption
    },
    error.InvalidMagic => {
        std.log.err("Invalid file format", .{});
        // File may not be a NorthstarDB database
    },
    else => return err,
};
```

### In-Memory Validation

Programmatic validation using the recovery module:

```zig
const recovery = @import("recovery");

// Check consistency between database and WAL
const result = try recovery.RecoveryManager.checkConsistency(
    allocator,
    "database.db",
    "database.wal"
);
defer result.deinit();

if (!result.is_consistent) {
    std.log.err("Database inconsistent: {} missing transactions", .{
        result.missing_txns.items.len
    });
    for (result.missing_txns.items) |txn_id| {
        std.log.err("  Missing TxnId: {}", .{txn_id});
    }
}

if (result.corrupted_records > 0) {
    std.log.err("Found {} corrupted WAL records", .{result.corrupted_records});
}
```

### Common Corruption Symptoms

| Symptom | Likely Cause | Detection Method |
|---------|--------------|------------------|
| `error.ChecksumMismatch` | Page corruption | Auto-detected on read |
| `error.InvalidMagic` | Wrong file type | Page header validation |
| `error.CorruptMeta` | Both meta pages invalid | Meta page validation |
| Missing data after crash | Incomplete commit | WAL consistency check |
| Tree traversal errors | B+tree structure corrupt | Tree validation |

## Recovery Procedures

### Recovery Decision Tree

```
Can open database?
├─ Yes → Can read specific keys?
│   ├─ Yes → Partial corruption → Export + Rebuild
│   └─ No → Tree corrupt → WAL replay
└─ No → Check WAL
    ├─ WAL valid → Replay WAL to new DB
    └─ WAL corrupt → Salvage data from pages
```

### Procedure 1: Automatic Crash Recovery

NorthstarDB automatically performs crash recovery on open:

```zig
// Recovery happens automatically on open
var db = try db.Db.open("database.db", allocator);

// What happens internally:
// 1. Read Meta A and Meta B
// 2. Validate checksums
// 3. Choose highest valid TxnId
// 4. Replay WAL if needed
// 5. Return consistent database
```

**Manual recovery trigger:**

```zig
const recovery = @import("recovery");

// Force explicit recovery
const result = try recovery.RecoveryManager.recoverDatabase(
    allocator,
    "database.db",
    "database.wal"
);
defer result.deinit();

if (result.recovery_needed) {
    std.log.info("Recovered {} transactions", .{result.recovered_txns});
    std.log.info("DB TxnId: {} -> WAL TxnId: {}", .{
        result.db_txn_id,
        result.wal_txn_id
    });
}
```

### Procedure 2: Export and Rebuild

When corruption is localized, export recoverable data:

```bash
# Export data to JSON (most resilient format)
zig-out/bin/dbdump export database.db json > backup.json

# Export to CSV for tabular data
zig-out/bin/dbdump export database.db csv > backup.csv

# Create new database from export
# (application-specific import logic)
```

**Programmatic export for rebuild:**

```zig
// Read all valid data from corrupted database
var db = try db.Db.open("corrupt.db", allocator);
defer db.close();

var r = try db.beginReadLatest();
defer r.close();

// Create new clean database
var new_db = try db.Db.create("recovered.db", allocator);
defer new_db.close();

var new_w = try new_db.beginWrite();
defer new_w.abort();

// Export data from old, import to new
var iter = try r.scan("");
while (try iter.next()) |entry| {
    try new_w.put(entry.key, entry.value);
}

_ = try new_w.commit();
```

### Procedure 3: WAL Replay

When database is corrupted but WAL is intact:

```zig
const wal = @import("wal");
const pager_mod = @import("pager");

// Open WAL (read-only for inspection)
var wal_inst = try wal.WriteAheadLog.open("database.wal", allocator);
defer wal_inst.deinit();

// Replay all valid records
const replay_data = try wal_inst.replayFrom(0, allocator);
defer replay_data.deinit();

std.log.info("Replaying {} commit records", .{
    replay_data.commit_records.items.len
});

// Create new database from WAL
var new_db = try db.Db.create("from_wal.db", allocator);
defer new_db.close();

var txn_counter: u64 = 0;
for (replay_data.commit_records.items) |record| {
    // Skip corrupted records
    if (!record.validateChecksum()) {
        std.log.warn("Skipping corrupted record at TxnId {}", .{record.txn_id});
        continue;
    }

    // Apply mutations from commit record
    var w = try new_db.beginWrite();
    defer w.abort();

    // Apply mutations based on commit record type
    // (implementation depends on commit record format)
    _ = try w.commit();
    txn_counter += 1;
}

std.log.info("Recovered {} transactions from WAL", .{txn_counter});
```

### Procedure 4: Page-Level Salvage

When higher-level structures are corrupt, salvage from pages:

```bash
# Use dbdump to inspect page structure
zig-out/bin/dbdump dump database.db > page_structure.txt

# Identify which pages are valid
# Look for pages with valid checksums in output
```

**Programmatic page salvage:**

```zig
const pager_mod = @import("pager");

// Open file directly (bypass DB layer)
const file = try std.fs.cwd().openFile("corrupt.db", .{ .mode = .read_only });
defer file.close();

const file_size = try file.getEndPos();
const page_size = 16_384; // DEFAULT_PAGE_SIZE
const page_count = file_size / page_size;

var salvage_file = try std.fs.cwd().createFile("salvaged.json", .{});
defer salvage_file.close();
var writer = salvage_file.writer();

try writer.writeAll("[\n");

var page_buffer: [16_384]u8 = undefined;
var first_entry = true;

var page_id: u64 = 2; // Skip meta pages
while (page_id < page_count) : (page_id += 1) {
    const offset = page_id * page_size;
    const bytes_read = try file.preadAll(&page_buffer, offset);

    if (bytes_read != page_size) continue;

    // Try to decode page header
    const header = pager_mod.PageHeader.decode(&page_buffer) catch |err| switch (err) {
        error.ChecksumMismatch => continue, // Skip corrupt pages
        else => continue,
    };

    // Only salvage leaf pages (contain actual data)
    if (header.page_type != .btree_leaf) continue;

    // Extract entries from leaf
    const leaf = pager_mod.BtreeLeafPayload{};
    var i: u16 = 0;
    while (i < 200) : (i += 1) { // MAX_KEYS_PER_LEAF
        const entry = leaf.getEntry(page_buffer[pager_mod.PageHeader.SIZE..], i) catch break;

        if (!first_entry) try writer.writeAll(",\n");
        first_entry = false;

        // Write as JSON
        try writer.print("  {{\"page\": {}, \"key_len\": {}, \"val_len\": {}}", .{
            page_id, entry.key.len, entry.value.len
        });
    }
}

try writer.writeAll("\n]\n");
```

## Data Salvage Strategies

### Strategy Selection

| Corruption Level | Strategy | Data Recovery |
|------------------|----------|---------------|
| **Single page** | Export + rebuild | 100% (minus corrupt page) |
| **Tree structure** | WAL replay | Up to 100% |
| **Meta pages** | Opposite meta | Up to 100% |
| **WAL corrupted** | Page salvage | Partial (valid pages only) |
| **Total corruption** | Forensic analysis | Minimal (raw data) |

### Priority Salvage Order

1. **Try opposite meta page** (if one is corrupt, other may be valid)
2. **Export all readable data** (use dbdump export)
3. **Replay WAL** (reconstruct from commit records)
4. **Page-level salvage** (extract from valid leaf pages)
5. **Raw data extraction** (last resort)

### Backup Before Recovery

```bash
# ALWAYS create backups before recovery
cp database.db database.db.backup
cp database.db.wal database.db.wal.backup  # If WAL exists

# Or use timestamped backups
cp database.db "database.db.$(date +%Y%m%d_%H%M%S).backup"
```

### Incremental Salvage

For large databases with scattered corruption:

```zig
// Salvage in batches to track progress
const batch_size = 1000;
var salvaged_keys: u64 = 0;

var r = try db.beginReadLatest();
defer r.close();

var new_db = try db.Db.create("recovered.db", allocator);
defer new_db.close();

var start_key: []const u8 = "";

while (true) {
    var batch_w = try new_db.beginWrite();
    defer batch_w.abort();

    var count: usize = 0;
    var iter = try r.rangeFrom(start_key);

    while (try iter.next()) |entry| {
        if (count >= batch_size) {
            start_key = entry.key; // Next batch starts here
            break;
        }

        // Skip keys that cause errors
        batch_w.put(entry.key, entry.value) catch |err| switch (err) {
            error.Corrupt => {
                std.log.warn("Skipping corrupt key: {s}", .{entry.key});
                continue;
            },
            else => return err,
        };

        count += 1;
    };

    if (count == 0) break; // Done

    _ = try batch_w.commit();
    salvaged_keys += count;

    std.log.info("Salvaged {} keys (batch complete)", .{salvaged_keys});
}
```

## Prevention Strategies

### Hardware Considerations

#### Use Reliable Storage

```bash
# Preferred: NVMe with power-loss protection
# Good: SATA SSD
# Avoid: HDD for production (higher corruption risk)

# Check device health
smartctl -a /dev/nvme0n1

# Monitor for errors
dmesg | grep -i error
```

#### Filesystem Configuration

```bash
# Use XFS or ext4 with data journaling
mkfs.xfs -f -d agcount=4 /dev/nvme0n1

# Mount with options for data integrity
mount -o noatime,allocsize=4M,barrier=1 /dev/nvme0n1 /data

# Options explained:
# - noatime: Reduce writes (no access time updates)
# - allocsize=4M: Delay allocation for better contiguous writes
# - barrier=1: Ensure write ordering (CRITICAL for crash safety)
```

### Application-Level Prevention

#### Graceful Shutdown

```zig
// Ensure proper shutdown
const SigHandler = struct {
    fn handler(sig: c_int) callconv(.C) void {
        _ = sig;
        std.log.info("Shutting down gracefully...", .{});

        // Commit any active transaction
        if (active_write_txn) |w| {
            w.commit() catch |err| {
                std.log.err("Failed to commit: {}", .{err});
            };
        }

        // Close database
        if (database) |db| {
            db.close();
        }

        std.process.exit(0);
    }
};

// Register signal handlers
_ = std.os.sigaction(std.os.SIG.INT, &.{
    .handler = .{ .handler = SigHandler.handler },
    .mask = std.os.empty_sigset,
    .flags = 0,
}, null);
```

#### Transaction Timeout

```zig
// Prevent long-running transactions
const MAX_TXN_DURATION_NS = 30_000_000_000; // 30 seconds

const TxnGuard = struct {
    start_time: i128,

    fn init() @This() {
        return .{
            .start_time = std.time.nanoTimestamp(),
        };
    }

    fn checkTimeout(self: @This()) !void {
        const elapsed = std.time.nanoTimestamp() - self.start_time;
        if (elapsed > MAX_TXN_DURATION_NS) {
            return error.TransactionTimeout;
        }
    }
};

// Usage
var w = try db.beginWrite();
defer w.abort();

var guard = TxnGuard.init();

try w.put("key1", "value1");
try guard.checkTimeout(); // Check periodically

try w.put("key2", "value2");
try guard.checkTimeout();

_ = try w.commit();
```

### Operational Best Practices

#### Regular Backups

```bash
# Backup script example
#!/bin/bash
BACKUP_DIR="/backups/northstar"
DB_FILE="/data/database.db"
WAL_FILE="/data/database.db.wal"

DATE=$(date +%Y%m%d_%H%M%S)
BACKUP_PATH="$BACKUP_DIR/$DATE"

mkdir -p "$BACKUP_PATH"

# Copy database (consistent snapshot via fsync)
cp "$DB_FILE" "$BACKUP_PATH/database.db"
if [ -f "$WAL_FILE" ]; then
    cp "$WAL_FILE" "$BACKUP_PATH/database.db.wal"
fi

# Verify backup
zig-out/bin/dbdump validate "$BACKUP_PATH/database.db"

if [ $? -eq 0 ]; then
    echo "Backup successful: $BACKUP_PATH"
else
    echo "Backup validation failed: $BACKUP_PATH"
    exit 1
fi
```

#### Regular Checkpointing

```zig
// Run periodic checkpoints to truncate WAL
const CHECKPOINT_INTERVAL_NS = 3600_000_000_000; // 1 hour

const checkpoint_thread = struct {
    fn run(db_path: []const u8, wal_path: []const u8) !void {
        while (true) {
            std.time.sleep(CHECKPOINT_INTERVAL_NS);

            const result = recovery.RecoveryManager.checkpoint(
                allocator,
                db_path,
                wal_path
            ) catch |err| {
                std.log.err("Checkpoint failed: {}", .{err});
                continue;
            };

            std.log.info("Checkpoint complete: {} bytes -> {} bytes", .{
                result.old_wal_size,
                result.new_wal_size
            });
        }
    }
};

// Spawn checkpoint thread
const thread = try std.Thread.spawn(.{}, checkpoint_thread.run, .{
    db_path,
    wal_path
});
thread.detach();
```

#### Health Monitoring

```bash
# Regular health checks
#!/bin/bash
DB_FILE="/data/database.db"

echo "=== Database Health Check ==="

# Run validation
zig-out/bin/dbdump validate "$DB_FILE"
VALIDATION_RESULT=$?

# Show statistics
zig-out/bin/dbdump stats "$DB_FILE"

if [ $VALIDATION_RESULT -ne 0 ]; then
    echo "WARNING: Database validation failed!"
    # Send alert
    curl -X POST https://alerts.example.com/northstar \
        -d "Database validation failed on $(hostname)"
    exit 1
fi

echo "Health check passed"
```

### Configuration for Production

```zig
const production_config = db.Db.Config{
    // Page cache: 50% of available RAM
    .page_cache_size = 8 * 1024 * 1024 * 1024, // 8GB

    // Enable detailed statistics
    .enable_stats = true,
    .stats_output_interval_ns = 60_000_000_000, // Every minute

    // Enable I/O stats for monitoring
    .enable_io_stats = true,

    // Error handling
    .error_on_corrupt = true, // Fail explicitly on corruption

    // WAL settings
    .wal_sync_mode = .fsync, // Maximum durability
    .wal_buffer_size = 16 * 1024 * 1024, // 16MB WAL buffer

    // Query logging for debugging
    .enable_query_logging = true,
    .slow_query_threshold_ns = 1_000_000, // Log queries > 1ms
};
```

## Recovery Checklist

Use this checklist when responding to corruption:

### Immediate Response
- [ ] Stop all writes to the database
- [ ] Create backups of corrupted files
- [ ] Document what happened (timestamps, error messages)
- [ ] Run `dbdump validate` to assess damage
- [ ] Check hardware health (smartctl, dmesg)

### Recovery Execution
- [ ] Determine corruption level (meta, tree, WAL)
- [ ] Select appropriate recovery procedure
- [ ] Export all recoverable data
- [ ] Create new database from export
- [ ] Validate recovered database
- [ ] Switch application to recovered database

### Post-Recovery
- [ ] Test application functionality
- [ ] Monitor for errors in logs
- [ ] Update backups with recovered database
- [ ] Investigate root cause
- [ ] Implement prevention measures
- [ ] Document incident for future reference

## Troubleshooting Scenarios

### Scenario 1: Power Loss During Commit

**Symptoms:** Database won't open, shows "corrupt meta" error

**Recovery:**
```bash
# Both meta pages may be inconsistent
# Check if WAL can help
zig-out/bin/dbdump validate database.db

# If WAL is valid, replay it
# NorthstarDB does this automatically on open
```

**Prevention:** Use UPS, ensure barrier=1 mount option

### Scenario 2: Disk Full During Write

**Symptoms:** Incomplete writes, checksum errors

**Recovery:**
```bash
# Free disk space first
df -h /data

# Export what's readable
zig-out/bin/dbdump export database.db json > partial.json

# Create new database on disk with space
```

**Prevention:** Monitor disk usage, alert at 80% full

### Scenario 3: Killed Process During Transaction

**Symptoms:** Some data missing after crash

**Recovery:**
```bash
# Automatic recovery handles this
# NorthstarDB uses atomic meta page switch
# Only committed transactions are visible
```

**Prevention:** Use SIGTERM, not SIGKILL

## Next Steps

Now that you understand corruption recovery:

- [Common Errors](./common-errors.mdx) - Error catalog with solutions
- [Performance Troubleshooting](./performance-troubleshooting.mdx) - Diagnose performance issues
- [Database Reference](../reference/db.md) - Database API documentation
- [WAL and Commit Stream](../concepts/commit-stream.mdx) - Understanding durability
