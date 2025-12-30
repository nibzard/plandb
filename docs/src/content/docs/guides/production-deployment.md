---
title: Production Deployment Guide
description: Deploy NorthstarDB in production environments with confidence using this comprehensive deployment guide.
---

import { Card, Cards } from '@astrojs/starlight/components';

This guide covers deploying NorthstarDB in production environments, from installation and configuration to monitoring, backup, and high availability.

<Cards>
  <Card title="Deploy" icon="rocket">
    Install and configure NorthstarDB for production.
  </Card>
  <Card title="Secure" icon="lock">
    Harden security with TLS and access controls.
  </Card>
  <Card title="Monitor" icon="activity">
    Observe metrics, logs, and set up alerts.
  </Card>
  <Card title="Scale" icon="layers">
    Plan capacity, backup, and high availability.
  </Card>
</Cards>

## Overview

NorthstarDB is designed for production deployment with:
- **Embedded deployment** - Runs in-process with your application
- **Crash-safe storage** - Atomic commits with WAL recovery
- **Massive read concurrency** - Unlimited concurrent readers
- **Zero operational overhead** - No separate database server to manage

### Deployment Models

| Model | Description | Use Case |
|-------|-------------|----------|
| **Embedded** | Database runs in-process | Single application, low latency |
| **Sidecar** | Separate process, shared storage | Microservices, shared state |
| **Replica** (planned) | Async replication to replicas | High availability, read scaling |

## Installation

### System Requirements

**Minimum Requirements:**
- CPU: 2 cores
- RAM: 4 GB
- Storage: 10 GB free space
- OS: Linux kernel 5.10+, macOS 12+, Windows 10+

**Recommended for Production:**
- CPU: 4+ cores
- RAM: 16+ GB
- Storage: NVMe SSD with power-loss protection
- OS: Linux (Ubuntu 22.04+, RHEL 9+)

### Build from Source

```bash
# Clone repository
git clone https://github.com/northstardb/northstar.git
cd northstar

# Build release binary
zig build -Drelease-fast

# Verify build
zig-out/bin/northstar --version
```

### Library Integration

Add NorthstarDB to your Zig project:

```zig
// build.zig
const northstar = b.dependency("northstar", .{
    .target = target,
    .optimize = optimize,
});

const northstar_module = northstar.module("northstar");
exe.root_module.addImport("northstar", northstar_module);

exe.linkLibrary(northstar.artifact("northstar"));
```

### Embedded Static Library

For C/C++ integration:

```c
// Include NorthstarDB as static library
#include "northstar.h"

// Open database
northstar_db_t* db = northstar_open("database.db", NULL);

// Begin transaction
northstar_txn_t* txn = northstar_begin_write(db);

// Put value
northstar_put(txn, "key", "value");

// Commit
northstar_commit(txn);

// Close
northstar_close(db);
```

## Configuration

### Production Configuration

```zig
const std = @import("std");
const db = @import("northstar");

fn productionConfig(allocator: std.mem.Allocator, db_path: []const u8) !db.Db.Config {
    // Detect available memory
    const page_size = std.mem.page_size;
    const total_memory = std.os.sysconf(.{ .phys_pages }) * page_size;

    // Allocate 50% of RAM to page cache
    const cache_size = @divFloor(total_memory, 2);

    return db.Db.Config{
        // File path
        .path = db_path,

        // Memory configuration
        .page_cache_size = cache_size,
        .write_buffer_size = 16 * 1024 * 1024, // 16MB

        // Concurrency
        .max_concurrent_reads = 0, // Unlimited readers
        .write_timeout_ms = 5000,

        // Durability
        .wal_enabled = true,
        .wal_sync_mode = .fsync, // Maximum durability
        .checkpoint_interval_ns = 300 * std.time.ns_per_s, // 5 minutes

        // Monitoring
        .enable_stats = true,
        .stats_output_interval_ns = 60 * std.time.ns_per_s,

        // Error handling
        .error_on_corrupt = true,
        .validation_level = .strict,
    };
}
```

### Environment-Specific Configurations

#### Development

```zig
const dev_config = db.Db.Config{
    .path = "/data/dev.db",
    .page_cache_size = 256 * 1024 * 1024, // 256MB
    .wal_enabled = true,
    .wal_sync_mode = .fdatasync, // Faster, slightly less durable
    .enable_stats = true,
};
```

#### Production

```zig
const prod_config = db.Db.Config{
    .path = "/data/prod.db",
    .page_cache_size = 8 * 1024 * 1024 * 1024, // 8GB
    .wal_enabled = true,
    .wal_sync_mode = .fsync, // Maximum durability
    .checkpoint_interval_ns = 60 * std.time.ns_per_s,
    .enable_stats = true,
    .error_on_corrupt = true,
};
```

#### Testing

```zig
const test_config = db.Db.Config{
    .path = ":memory:", // In-memory database
    .page_cache_size = 16 * 1024 * 1024, // 16MB
    .wal_enabled = false,
    .enable_stats = false,
};
```

## Storage Configuration

### Filesystem Selection

**Recommended filesystems:**

| Filesystem | Pros | Cons |
|------------|------|------|
| **XFS** | Best performance, excellent NVMe support | Not Windows-compatible |
| **ext4** | Widely supported, stable | Slightly slower than XFS |
| **ZFS** | Advanced features, compression | Higher memory overhead |

**Not recommended:** NTFS, FAT32, exFAT (no proper fsync semantics)

### NVMe Optimization

```bash
# Format NVMe with optimal settings
sudo mkfs.xfs -f -d agcount=4 /dev/nvme0n1

# Mount with performance options
sudo mount -o noatime,allocsize=4M,barrier=1 /dev/nvme0n1 /data

# Verify mount options
mount | grep /data
# /dev/nvme0n1 on /data type xfs (rw,noatime,attr2,inode64,logbufs=8,logbsize=64k,sunit=512,swidth=512,allocsize=4M,barrier=1)
```

**Mount options explained:**
- `noatime` - Disable access time updates (reduces writes)
- `allocsize=4M` - Delay allocation for better contiguous writes
- `barrier=1` - Ensure write ordering (CRITICAL for crash safety)
- `rw` - Read-write mode

### File Descriptor Limits

```bash
# Check current limit
ulimit -n

# Increase temporarily
ulimit -n 65536

# Set permanently in /etc/security/limits.conf
echo "* soft nofile 65536" | sudo tee -a /etc/security/limits.conf
echo "* hard nofile 65536" | sudo tee -a /etc/security/limits.conf

# Verify for running process
cat /proc/<PID>/limits | grep "Max open files"
```

### Swap Configuration

```bash
# Disable swap for database workloads
sudo swapoff -a

# Verify
free -h
# Swap:         0B          0B          0B

# Permanently disable in /etc/fstab
# Comment out swap lines
```

## Security Hardening

### File Permissions

```bash
# Create database directory
sudo mkdir -p /data/northstar

# Set ownership to application user
sudo chown appuser:appuser /data/northstar

# Restrictive permissions
sudo chmod 700 /data/northstar

# Verify
ls -ld /data/northstar
# drwx------ 2 appuser appuser 4096 Dec 30 12:00 /data/northstar
```

### Database File Encryption

NorthstarDB supports encryption at rest (planned feature). For now, use filesystem-level encryption:

```bash
# LUKS encryption for Linux
sudo cryptsetup luksFormat /dev/nvme0n1
sudo cryptsetup open /dev/nvme0n1 northstar_crypt
sudo mkfs.xfs /dev/mapper/northstar_crypt
sudo mount /dev/mapper/northstar_crypt /data

# Verify encryption
sudo cryptsetup status northstar_crypt
```

### Application-Level Security

```zig
// Validate user input before database operations
fn validateKey(key: []const u8) !void {
    if (key.len == 0) return error.EmptyKey;
    if (key.len > 1024) return error.KeyTooLong;
    // Check for path traversal
    if (std.mem.indexOf(u8, key, "..") != null) return error.InvalidKey;
    if (std.mem.indexOf(u8, key, "/") != null) return error.InvalidKey;
}

// Sanitize values to prevent injection attacks
fn validateValue(value: []const u8) !void {
    if (value.len > 16 * 1024 * 1024) return error.ValueTooLarge; // 16MB max
}

// Use validated operations
fn safePut(db: *db.Db, key: []const u8, value: []const u8) !void {
    try validateKey(key);
    try validateValue(value);

    var w = try db.beginWrite();
    defer w.abort();

    try w.put(key, value);
    _ = try w.commit();
}
```

### TLS Configuration (Future)

When network replication is available:

```zig
const tls_config = db.Db.TLSConfig{
    .enabled = true,
    .cert_path = "/etc/northstar/cert.pem",
    .key_path = "/etc/northstar/key.pem",
    .ca_path = "/etc/northstar/ca.pem",
    .verify_mode = .required, // Verify peer certificates
    .min_version = .TLSv1_3, // Require TLS 1.3
};

const config = db.Db.Config{
    .tls = tls_config,
    // ...
};
```

## Monitoring and Observability

### Built-in Metrics

NorthstarDB provides built-in performance metrics:

```zig
// Get throughput statistics
const throughput = try db.getThroughputStats();
std.log.info("Read ops/s: {}", .{throughput.read_ops});
std.log.info("Write ops/s: {}", .{throughput.write_ops});

// Get latency statistics
const latency = try db.getLatencyStats(.{
    .window_ns = 60 * std.time.ns_per_s, // 1 minute window
});
std.log.info("P50 read latency: {} us", .{latency.read_p50_us});
std.log.info("P99 read latency: {} us", .{latency.read_p99_us});
std.log.info("P50 write latency: {} us", .{latency.write_p50_us});
std.log.info("P99 write latency: {} us", .{latency.write_p99_us});

// Get cache statistics
const cache = try db.getCacheStats();
std.log.info("Cache hit rate: {d:.2}%", .{cache.hit_rate * 100});
std.log.info("Cache size: {} MB", .{cache.size_bytes / 1024 / 1024});
```

### Prometheus Exporter (Example)

```zig
const std = @import("std");

pub fn exportMetrics(db: *db.Db, writer: anytype) !void {
    const throughput = try db.getThroughputStats();
    const latency = try db.getLatencyStats(.{
        .window_ns = 60 * std.time.ns_per_s,
    });
    const cache = try db.getCacheStats();

    try writer.print(
        \\# HELP northstar_read_ops_total Total read operations
        \\# TYPE northstar_read_ops_total counter
        \\northstar_read_ops_total {}
        \\
        \\# HELP northstar_write_ops_total Total write operations
        \\# TYPE northstar_write_ops_total counter
        \\northstar_write_ops_total {}
        \\
        \\# HELP northstar_read_latency_us Read latency in microseconds
        \\# TYPE northstar_read_latency_us histogram
        \\northstar_read_latency_us{{quantile="0.5"}} {}
        \\northstar_read_latency_us{{quantile="0.99"}} {}
        \\
        \\# HELP northstar_cache_hit_ratio Cache hit rate ratio
        \\# TYPE northstar_cache_hit_ratio gauge
        \\northstar_cache_hit_ratio {d:.3}
        \\
    , .{
        throughput.read_ops,
        throughput.write_ops,
        latency.read_p50_us,
        latency.read_p99_us,
        cache.hit_rate,
    });
}
```

### Health Check Endpoint

```zig
pub fn healthCheck(db: *db.Db) !HealthStatus {
    const HealthStatus = struct {
        healthy: bool,
        txn_id: u64,
        last_commit: i128,
        uptime_ns: i128,
    };

    // Try to begin a read transaction
    var r = db.beginReadLatest() catch |err| {
        std.log.err("Health check failed: {}", .{err});
        return HealthStatus{
            .healthy = false,
            .txn_id = 0,
            .last_commit = 0,
            .uptime_ns = 0,
        };
    };
    defer r.close();

    const stats = try db.getDbStats();

    return HealthStatus{
        .healthy = true,
        .txn_id = stats.current_txn_id,
        .last_commit = stats.last_commit_time_ns,
        .uptime_ns = stats.uptime_ns,
    };
}

// HTTP endpoint example
// GET /health
// Returns: {"healthy":true,"txn_id":1234,"last_commit":1703947200000000000,"uptime_ns":3600000000000}
```

### Key Metrics to Monitor

| Metric | Type | Description | Alert Threshold |
|--------|------|-------------|-----------------|
| `northstar_read_ops_total` | Counter | Total read operations | - |
| `northstar_write_ops_total` | Counter | Total write operations | - |
| `northstar_read_latency_us` | Histogram | Read latency | P99 > 10ms |
| `northstar_write_latency_us` | Histogram | Write latency | P99 > 100ms |
| `northstar_cache_hit_ratio` | Gauge | Cache hit rate | < 0.8 |
| `northstar_page_faults_total` | Counter | Page faults | Increasing trend |
| `northstar_wal_size_bytes` | Gauge | WAL file size | > 1GB |
| `northstar_active_transactions` | Gauge | Active transactions | > 100 |

### Alerting Rules (Prometheus)

```yaml
groups:
  - name: northstar_alerts
    rules:
      - alert: NorthstarHighLatency
        expr: northstar_read_latency_us{quantile="0.99"} > 10000
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "High read latency on {{ $labels.instance }}"
          description: "P99 read latency is {{ $value }}us"

      - alert: NorthstarLowCacheHitRate
        expr: northstar_cache_hit_ratio < 0.8
        for: 10m
        labels:
          severity: warning
        annotations:
          summary: "Low cache hit rate on {{ $labels.instance }}"
          description: "Cache hit rate is {{ $value }}"

      - alert: NorthstarHighWALSize
        expr: northstar_wal_size_bytes > 1073741824
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "Large WAL file on {{ $labels.instance }}"
          description: "WAL size is {{ $value }} bytes"
```

### Logging Configuration

```zig
// Configure structured logging
const log_config = db.Db.LogConfig{
    .enabled = true,
    .level = .info, // .debug, .info, .warn, .error
    .output = .file, // .stdout, .file, .syslog
    .file_path = "/var/log/northstar/db.log",
    .rotation = .daily,
    .retention_days = 30,
    .format = .json, // .text, .json
};

const config = db.Db.Config{
    .log = log_config,
    // ...
};
```

## Backup and Recovery

### Backup Strategies

#### Full Backup

```bash
#!/bin/bash
# backup.sh - Full backup script

DB_FILE="/data/northstar/prod.db"
BACKUP_DIR="/backup/northstar"
DATE=$(date +%Y%m%d_%H%M%S)
BACKUP_PATH="$BACKUP_DIR/$DATE"

mkdir -p "$BACKUP_PATH"

# Create consistent backup using cp (which preserves file integrity)
cp "$DB_FILE" "$BACKUP_PATH/prod.db"

# Backup WAL if exists
if [ -f "$DB_FILE.wal" ]; then
    cp "$DB_FILE.wal" "$BACKUP_PATH/prod.db.wal"
fi

# Validate backup
zig-out/bin/dbdump validate "$BACKUP_PATH/prod.db"

if [ $? -eq 0 ]; then
    echo "Backup successful: $BACKUP_PATH"
    # Cleanup old backups (keep last 7 days)
    find "$BACKUP_DIR" -maxdepth 1 -mtime +7 -exec rm -rf {} \;
else
    echo "Backup validation failed: $BACKUP_PATH"
    rm -rf "$BACKUP_PATH"
    exit 1
fi
```

#### Incremental Backup (using WAL)

```bash
#!/bin/bash
# incremental_backup.sh - Incremental backup using WAL

DB_FILE="/data/northstar/prod.db"
WAL_FILE="$DB_FILE.wal"
BACKUP_DIR="/backup/northstar"
INCREMENTAL_DIR="$BACKUP_DIR/incremental"
DATE=$(date +%Y%m%d_%H%M%S)

mkdir -p "$INCREMENTAL_DIR"

# Copy WAL only (smaller, faster)
if [ -f "$WAL_FILE" ]; then
    cp "$WAL_FILE" "$INCREMENTAL_DIR/wal_$DATE"

    # Record LSN position
    LSN=$(zig-out/bin/dbdump stats "$DB_FILE" | grep "Last LSN" | awk '{print $3}')
    echo "$DATE $LSN" >> "$INCREMENTAL_DIR/backup_index.txt"

    echo "Incremental backup: $DATE (LSN: $LSN)"
else
    echo "No WAL file found"
fi
```

#### Programmatic Backup

```zig
const std = @import("std");
const db = @import("northstar");

pub fn backupDatabase(
    db: *db.Db,
    backup_path: []const u8,
    allocator: std.mem.Allocator
) !void {
    // Begin read transaction for consistent snapshot
    var r = try db.beginReadLatest();
    defer r.close();

    // Create backup file
    var backup_file = try std.fs.cwd().createFile(backup_path, .{
        .read = true,
        .truncate = true,
    });
    defer backup_file.close();

    // Export all data
    var iter = try r.scan("");
    var count: usize = 0;

    while (try iter.next()) |entry| {
        // Write as JSON lines
        try backup_file.writer().print(
            "{{\"key\":\"{s}\",\"value\":\"{s}\"}}\n",
            .{ entry.key, entry.value }
        );
        count += 1;
    }

    std.log.info("Backup complete: {} keys exported to {s}", .{count, backup_path});
}
```

### Restore Procedures

#### Restore from Full Backup

```bash
#!/bin/bash
# restore.sh - Restore from backup

BACKUP_PATH=$1  # e.g., /backup/northstar/20231230_120000
DB_FILE="/data/northstar/prod.db"

# Stop application
systemctl stop myapp

# Backup current database (just in case)
mv "$DB_FILE" "$DB_FILE.before_restore"

# Restore from backup
cp "$BACKUP_PATH/prod.db" "$DB_FILE"

# Validate restored database
zig-out/bin/dbdump validate "$DB_FILE"

if [ $? -eq 0 ]; then
    echo "Restore successful"
    # Start application
    systemctl start myapp
else
    echo "Restore validation failed"
    # Rollback
    mv "$DB_FILE.before_restore" "$DB_FILE"
    systemctl start myapp
    exit 1
fi
```

#### Restore with WAL Replay

```zig
pub fn restoreWithWAL(
    db_path: []const u8,
    wal_path: []const u8,
    allocator: std.mem.Allocator
) !void {
    const recovery = @import("recovery");

    // Open and validate database
    var db = try db.Db.open(db_path, allocator);
    defer db.close();

    // Replay WAL
    const result = try recovery.RecoveryManager.recoverDatabase(
        allocator,
        db_path,
        wal_path
    );
    defer result.deinit();

    if (result.recovery_needed) {
        std.log.info("Replayed {} transactions from WAL", .{
            result.recovered_txns
        });
    }

    std.log.info("Restore complete. DB TxnId: {}, WAL TxnId: {}", .{
        result.db_txn_id,
        result.wal_txn_id
    });
}
```

### Disaster Recovery

#### Recovery Checklist

```markdown
## Disaster Recovery Checklist

### Pre-Incident Preparation
- [ ] Regular automated backups (daily)
- [ ] Off-site backup storage
- [ ] Backup restoration tested monthly
- [ ] Recovery procedures documented
- [ ] Contact list established

### During Incident
- [ ] Identify failure scope
- [ ] Declare incident status
- [ ] Assemble response team
- [ ] Estimate recovery time

### Recovery Execution
- [ ] Stop writes to corrupted database
- [ ] Create backup of corrupted state
- [ ] Identify last known good backup
- [ ] Restore from backup
- [ ] Replay incremental backups/WAL
- [ ] Validate recovered database
- [ ] Switch traffic to recovered instance

### Post-Recovery
- [ ] Verify application functionality
- [ ] Monitor for errors
- [ ] Update backups
- [ ] Document root cause
- [ ] Implement prevention measures
- [ ] Conduct post-mortem
```

## High Availability

### Planned High Availability Features

NorthstarDB will support HA in future releases:

- **Asynchronous replication** - Replica lag configurable
- **Synchronous replication** - Zero data loss option
- **Automatic failover** - Leader election on primary failure
- **Read replicas** - Scale read workload

### Current Workaround: Active-Passive

```bash
#!/bin/bash
# rsync_based_replication.sh - Simple replication for current version

PRIMARY_DB="/data/northstar/prod.db"
REPLICA_HOST="replica.example.com"
REPLICA_DB="/data/northstar/prod.db"

# Periodic rsync to replica
while true; do
    # Create checkpoint first for consistency
    zig-out/bin/dbdump checkpoint "$PRIMARY_DB"

    # Rync database file
    rsync -avz --delete "$PRIMARY_DB" "$REPLICA_HOST:$REPLICA_DB"

    # Validate on replica
    ssh "$REPLICA_HOST" "zig-out/bin/dbdump validate $REPLICA_DB"

    if [ $? -eq 0 ]; then
        echo "Replication successful: $(date)"
    else
        echo "Replication failed: $(date)"
        # Send alert
    fi

    sleep 60  # Sync every minute
done
```

### Manual Failover Procedure

```bash
#!/bin/bash
# failover.sh - Manual failover to replica

REPLICA_HOST="replica.example.com"
VIP="192.168.1.100"  # Virtual IP

# On primary:
# 1. Stop application
systemctl stop myapp

# 2. Flush any pending writes
sync

# On replica:
# 3. Verify database is consistent
ssh "$REPLICA_HOST" "zig-out/bin/dbdump validate /data/northstar/prod.db"

# 4. Assign virtual IP
ssh "$REPLICA_HOST" "ip addr add $VIP/24 dev eth0"

# 5. Start application on replica
ssh "$REPLICA_HOST" "systemctl start myapp"

# 6. Update DNS/load balancer
# Point to replica IP

echo "Failover complete. New primary: $REPLICA_HOST"
```

## Capacity Planning

### Sizing Guidelines

#### Memory

| Workload | Cache Size | Total RAM |
|----------|------------|-----------|
| Small (< 1M keys) | 256 MB | 2 GB |
| Medium (1-10M keys) | 2 GB | 8 GB |
| Large (10-100M keys) | 8 GB | 16 GB |
| XLarge (> 100M keys) | 32 GB | 64 GB |

#### Storage

Calculate storage requirements:

```
Base storage = (key_size + value_size + overhead) * key_count * growth_factor
WAL storage = write_ops_per_day * avg_txn_size * wal_retention_days
Backup storage = base_storage * backup_retention_days

Example for 10M keys:
- Average key: 32 bytes
- Average value: 1 KB
- Overhead: 100 bytes per key
- Growth factor: 1.5x
- WAL retention: 7 days
- Backup retention: 30 days

Base storage = (32 + 1024 + 100) * 10,000,000 * 1.5 = 17.4 GB
WAL storage (10K writes/day) = 10,000 * 2048 * 7 = 143 MB
Backup storage = 17.4 * 30 = 522 GB
Total required = 540 GB
```

#### CPU

| Operation | CPU Cost | Threads Needed |
|-----------|----------|----------------|
| Point read | Low | 1 per 100K ops/s |
| Point write | Medium | 1 per 10K ops/s |
| Range scan | Medium | Depends on result size |
| Snapshot open | Very low | Unlimited |

### Performance Baselines

Run baselines before production:

```bash
# Load test for capacity planning
zig build run -- run --suite macro --filter "bench/load/concurrent_readers_1000"

# Compare with your requirements
# Example: Need 50K reads/s at P99 < 5ms
```

### Scalability Planning

```zig
// Estimate capacity
fn estimateCapacity(
    keys_per_second: u64,
    avg_key_size: u64,
    avg_value_size: u64,
    growth_months: u64
) CapacityEstimate {
    const seconds_per_month = 30 * 24 * 3600;
    const total_keys = keys_per_second * seconds_per_month * growth_months;

    const storage_per_key = avg_key_size + avg_value_size + 100; // 100B overhead
    const total_storage = total_keys * storage_per_key * 3 / 2; // 1.5x for growth

    const page_cache = @min(total_storage / 2, 16 * 1024 * 1024 * 1024); // Max 16GB

    return CapacityEstimate{
        .total_keys = total_keys,
        .storage_bytes = total_storage,
        .recommended_cache = page_cache,
        .recommended_ram = page_cache * 2,
    };
}
```

## Operational Procedures

### Upgrades

#### In-Place Upgrade

```bash
#!/bin/bash
# upgrade.sh - Upgrade NorthstarDB

NEW_VERSION="v0.2.0"
OLD_VERSION=$(northstar --version)

# 1. Backup before upgrade
./backup.sh

# 2. Download new version
wget https://github.com/northstardb/northstar/releases/download/$NEW_VERSION/northstar-linux-amd64.tar.gz

# 3. Verify checksum
sha256sum -c CHECKSUMS

# 4. Stop application
systemctl stop myapp

# 5. Extract new binary
tar -xzf northstar-linux-amd64.tar.gz
cp northstar /usr/local/bin/

# 6. Verify upgrade
northstar --version

# 7. Start application
systemctl start myapp

# 8. Run smoke tests
zig build test

# 9. Monitor logs
tail -f /var/log/northstar/db.log
```

#### Rolling Upgrade (Multiple Instances)

```bash
#!/bin/bash
# rolling_upgrade.sh - Rolling upgrade for multiple instances

INSTANCES=("app1.example.com" "app2.example.com" "app3.example.com")

for instance in "${INSTANCES[@]}"; do
    echo "Upgrading $instance..."

    # Stop instance
    ssh "$instance" "systemctl stop myapp"

    # Upgrade binary
    ssh "$instance" "wget -O /tmp/northstar.tar.gz https://..."
    ssh "$instance" "tar -xzf /tmp/northstar.tar.gz -C /usr/local/bin/"

    # Start instance
    ssh "$instance" "systemctl start myapp"

    # Health check
    sleep 10
    curl -f "http://$instance:8080/health" || {
        echo "Health check failed for $instance"
        exit 1
    }

    echo "Upgraded $instance successfully"
done
```

### Maintenance Windows

```bash
#!/bin/bash
# maintenance.sh - Perform maintenance tasks

echo "Starting maintenance window..."

# 1. Graceful drain of traffic
# (application-specific)

# 2. Checkpoint database
zig-out/bin/dbdump checkpoint /data/northstar/prod.db

# 3. Backup
./backup.sh

# 4. Vacuum/rebuild if needed
# zig-out/bin/dbdump vacuum /data/northstar/prod.db

# 5. Restore traffic
# (application-specific)

echo "Maintenance complete"
```

### Monitoring Setup

```bash
#!/bin/bash
# setup_monitoring.sh - Configure monitoring

# Install Node Exporter for system metrics
wget https://github.com/prometheus/node_exporter/releases/download/v1.7.0/node_exporter-1.7.0.linux-amd64.tar.gz
tar -xzf node_exporter-1.7.0.linux-amd64.tar.gz
sudo cp node_exporter-1.7.0.linux-amd64/node_exporter /usr/local/bin/

# Create systemd service
sudo tee /etc/systemd/system/node_exporter.service > /dev/null <<EOF
[Unit]
Description=Node Exporter
After=network.target

[Service]
ExecStart=/usr/local/bin/node_exporter
Restart=always

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl enable node_exporter
sudo systemctl start node_exporter

# Verify
curl http://localhost:9100/metrics
```

## Deployment Checklist

Use this checklist before going to production:

### Pre-Deployment
- [ ] Hardware requirements met (CPU, RAM, Storage)
- [ ] Operating system updated to supported version
- [ ] Filesystem configured (XFS/ext4 with proper options)
- [ ] File descriptor limits increased
- [ ] Swap disabled or minimized
- [ ] Network configured (if using replication)
- [ ] Firewalls configured
- [ ] TLS certificates obtained (if needed)

### Database Configuration
- [ ] Production configuration applied
- [ ] Page cache sized appropriately
- [ ] WAL enabled and configured
- [ ] Checkpoint interval set
- [ ] Error handling configured
- [ ] Statistics enabled
- [ ] Logging configured

### Security
- [ ] File permissions restricted
- [ ] Database directory owned by application user
- [ ] Encryption at rest enabled (if needed)
- [ ] TLS configured (if needed)
- [ ] Input validation implemented
- [ ] Backup encryption enabled

### Monitoring
- [ ] Metrics collection configured
- [ ] Prometheus/Grafana dashboards created
- [ ] Alerting rules configured
- [ ] Health check endpoint implemented
- [ ] Log aggregation configured
- [ ] Uptime monitoring configured

### Backup and Recovery
- [ ] Automated backup schedule configured
- [ ] Backup retention policy defined
- [ ] Off-site backup storage configured
- [ ] Backup restoration tested
- [ ] Disaster recovery plan documented
- [ ] Recovery contact list established

### Performance
- [ ] Baseline benchmarks run
- [ ] Performance targets met
- [ ] Load testing completed
- [ ] Capacity planning completed
- [ ] Scaling plan documented

### Documentation
- [ ] Architecture diagram updated
- [ ] Runbook created
- [ ] On-call procedures documented
- [ ] Escalation paths defined
- [ ] Post-mortem process established

## Troubleshooting

### Common Issues

#### Database Won't Open

```bash
# Check file permissions
ls -la /data/northstar/prod.db

# Validate database file
zig-out/bin/dbdump validate /data/northstar/prod.db

# Check system logs
dmesg | tail -50
journalctl -xe
```

#### Poor Performance

```bash
# Check cache hit rate
zig-out/bin/dbdump stats /data/northstar/prod.db | grep "Cache"

# Increase cache size if hit rate < 80%
# Check I/O wait
iostat -x 1

# Check memory
free -h
```

#### High Memory Usage

```bash
# Check memory by process
ps aux --sort=-%mem | head -20

# Check for memory leaks
valgrind --leak-check=full --log-file=leak.log ./myapp

# Reduce cache size if needed
```

#### Disk Full

```bash
# Check disk usage
df -h /data

# Find large files
du -sh /data/* | sort -rh | head -10

# Check WAL size
ls -lh /data/northstar/*.wal

# Force checkpoint to truncate WAL
zig-out/bin/dbdump checkpoint /data/northstar/prod.db
```

## Next Steps

Now that you understand production deployment:

- [Performance Tuning Guide](./performance-tuning.md) - Optimize for your workload
- [Corruption Recovery Guide](./corruption-recovery.md) - Handle database issues
- [Load Testing Guide](/load-testing.md) - Validate under production traffic
- [Snapshots & Time Travel](./snapshots-time-travel.md) - Query historical data

## Further Reading

- [File Format Specification](../../reference/file-format.md) - On-disk format details
- [Database API Reference](../../reference/db.md) - Complete API documentation
- [Production Best Practices](https://northstardb.dev/blog/production-best-practices) - Blog post with real-world tips
