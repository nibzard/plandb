# Raft Snapshotting - Natural Language Specification

**Status**: Draft
**Version**: 1.0
**Dependencies**: [10-raft-state.md](./10-raft-state.md), [10-raft-rpc.md](./10-raft-rpc.md)

## Purpose

This specification defines the Raft snapshotting mechanism for log compaction. Snapshots allow the Raft log to be truncated, preventing unbounded growth and enabling new nodes to bootstrap quickly.

## Snapshot Overview

1. When log exceeds threshold, create snapshot of state machine
2. Snapshot includes all state up to last_included_index
3. Discard log entries up to last_included_index
4. Persist snapshot to disk
5. Install snapshot on lagging followers via InstallSnapshot RPC

## Types

### Snapshot

**Description**: Complete snapshot of Raft state machine.

**Fields**:
- last_included_index: u64 - Index of last log entry included in snapshot
- last_included_term: u64 - Term of last_included_index
- data: Vec u8 - Serialized state machine (MVCC snapshot, B+tree pages)
- config: Configuration - Cluster configuration at snapshot time
- checksum: u64 - Checksum of data field

**Size**: Variable (data size plus 48 bytes metadata)

**Invariants**:
- last_included_index is monotonically increasing
- last_included_term matches term of entry at last_included_index
- checksum validates data integrity

### SnapshotMetadata

**Description**: Metadata about snapshot.

**Fields**:
- created_at: Instant - When snapshot was created
- entry_count: u64 - Number of log entries included in snapshot
- data_size: u64 - Size of snapshot data in bytes
- version: u32 - Snapshot format version

## Functions

### create_snapshot(&self) -> Result Snapshot

**Purpose**: Create snapshot of current state machine.

**Returns**: Snapshot instance

**Algorithm**:
1. Determine last_included_index (min(commit_index, last_log_index()))
2. Determine last_included_term (term at last_included_index)
3. Create MVCC snapshot of state machine
4. Serialize B+tree pages
5. Serialize cluster configuration
6. Concatenate all serialized data
7. Calculate checksum of data
8. Create Snapshot with all fields
9. Return snapshot

**Error Conditions**:
- IoError: Failed to read state or serialize data
- SerializationError: Failed to serialize state machine

**Concurrency**: Should be called with state machine lock held.

### install_snapshot(&self, snapshot: Snapshot) -> Result

**Purpose**: Install snapshot on this node (follower bootstrap).

**Parameters**:
- snapshot: Snapshot - Snapshot to install

**Algorithm**:
1. Validate snapshot checksum
2. Discard entire log up to last_included_index
3. If log has entry with same index and term as snapshot:
    a. Retain log entries after last_included_index
4. Otherwise:
    a. Discard entire log
5. Apply snapshot data to state machine:
    a. Deserialize MVCC snapshot
    b. Deserialize B+tree pages
    c. Apply cluster configuration
6. Update commit_index to last_included_index
7. Update last_applied to last_included_index
8. Persist state
9. Return success

**Error Conditions**:
- ChecksumError: Snapshot checksum validation failed
- IoError: Failed to write data or persist state
- ApplyError: Failed to apply snapshot to state machine

**Concurrency**: Should be called with state machine and persistent state locks held.

### persist_snapshot(&self, snapshot: Snapshot, path: Path) -> Result

**Purpose**: Write snapshot to disk.

**Parameters**:
- snapshot: Snapshot - Snapshot to persist
- path: Path - Path to snapshot file

**Algorithm**:
1. Serialize snapshot to bytes
2. Calculate checksum
3. Write to temporary file
4. Sync to disk
5. Rename to final path
6. Return success

**Error Conditions**:
- IoError: Failed to write or sync file
- SerializationError: Failed to serialize snapshot

**Concurrency**: Should not be called concurrently on same path.

### load_snapshot(path: Path) -> Result Snapshot

**Purpose**: Load snapshot from disk.

**Parameters**:
- path: Path - Path to snapshot file

**Returns**: Loaded Snapshot

**Algorithm**:
1. Read file contents
2. Deserialize to Snapshot
3. Validate checksum
4. Return snapshot

**Error Conditions**:
- IoError: Failed to read file
- DeserializeError: Failed to deserialize snapshot
- ChecksumError: Checksum validation failed

**Concurrency**: Should not be called concurrently on same path.

### truncate_log(&self, last_included_index: u64)

**Purpose**: Truncate log up to last_included_index.

**Parameters**:
- last_included_index: u64 - Index to truncate to

**Algorithm**:
1. If log has entry with same index and term as snapshot:
    a. Remove all entries before last_included_index
2. Otherwise:
    a. Remove all entries up to and including last_included_index
3. Persist log
4. Return success

**Concurrency**: Should be called with persistent state lock held.

## InstallSnapshot RPC

### Sender (Leader)

**Invoked when**: Follower is too far behind (next_index points to entry before snapshot)

**Algorithm**:
1. Read snapshot from disk in chunks (1MB max)
2. For each chunk:
    a. Create InstallSnapshotArgs with chunk data
    b. Send RPC to follower
    c. Wait for reply
    d. If reply.term is greater than current_term:
        i. Step down
        ii. Abort snapshot installation
3. Update follower next_index to (last_included_index + 1)

### Receiver (Follower)

**Invoked when**: Leader sends InstallSnapshot RPC

**Algorithm**:
1. If args.term is less than current_term:
    a. Return reply with term = current_term
2. If args.term is greater than current_term:
    a. Update current_term
    b. Become follower
3. Create or append to snapshot file
4. If args.done is true:
    a. Validate checksum
    b. Install snapshot (call install_snapshot())
5. Return reply with term = current_term

## Snapshot Triggers

### Size-Based Trigger

Create snapshot when log size exceeds threshold:
- snapshot_size_threshold: Default 100MB
- Checked after each log append

### Entry-Based Trigger

Create snapshot when log entry count exceeds threshold:
- snapshot_entry_threshold: Default 10,000 entries
- Checked after each log append

### Manual Trigger

Create snapshot on operator command:
- Admin API call to trigger snapshot
- Useful before maintenance or upgrades

## Snapshot Bootstrapping

### New Node Bootstrapping

When new node joins cluster:
1. Node starts with empty log
2. Node discovers leader
3. Leader sends InstallSnapshot RPC
4. Node installs snapshot
5. Node catches up via normal log replication

### Lagging Node Bootstrapping

When node falls too far behind:
1. Leader detects follower next_index points to entry before snapshot
2. Leader sends InstallSnapshot RPC instead of AppendEntries
3. Follower installs snapshot
4. Leader updates follower next_index
5. Normal replication resumes

## Rust Implementation Guidance

### Snapshot Creation

```rust
pub fn create_snapshot(&self) -> Result<Snapshot> {
    let last_included_index = self.commit_index.load(Ordering::SeqCst);
    let last_included_term = self.log.get(last_included_index)?.term;

    let mvcc_snapshot = self.state_machine.create_mvcc_snapshot()?;
    let btree_data = self.state_machine.serialize_btree()?;
    let config = self.cluster.get_configuration();

    let mut data = Vec::new();
    data.extend_from_slice(&mvcc_snapshot);
    data.extend_from_slice(&btree_data);
    data.extend_from_slice(&config.serialize()?);

    let checksum = crc64(&data);

    Ok(Snapshot {
        last_included_index,
        last_included_term,
        data,
        config,
        checksum,
    })
}
```

### Snapshot Installation

```rust
pub fn install_snapshot(&mut self, snapshot: Snapshot) -> Result<()> {
    if crc64(&snapshot.data) != snapshot.checksum {
        return Err(Error::ChecksumMismatch);
    }

    // Truncate log
    if let Some(entry) = self.log.get(snapshot.last_included_index) {
        if entry.term == snapshot.last_included_term {
            self.log.truncate(snapshot.last_included_index);
        } else {
            self.log.clear();
        }
    }

    // Apply to state machine
    let mut cursor = std::io::Cursor::new(&snapshot.data);
    let mvcc_snapshot = MVCCSnapshot::deserialize(&mut cursor)?;
    let btree_data = read_btree_data(&mut cursor)?;
    let config = Configuration::deserialize(&mut cursor)?;

    self.state_machine.apply_mvcc_snapshot(mvcc_snapshot)?;
    self.state_machine.apply_btree_data(btree_data)?;
    self.cluster.apply_configuration(config)?;

    self.commit_index.store(snapshot.last_included_index, Ordering::SeqCst);
    self.last_applied.store(snapshot.last_included_index, Ordering::SeqCst);

    Ok(())
}
```

## Testing Strategy

Unit tests:
- Snapshot creation and serialization
- Checksum validation
- Log truncation after snapshot

Integration tests:
- Install snapshot to new node
- Install snapshot to lagging node
- Snapshot with log entries after snapshot point

Property-based tests:
- Snapshot always has consistent index and term
- Checksum always validates
- Snapshot size is less than log size
