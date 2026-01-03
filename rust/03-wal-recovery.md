# WAL Recovery

## Purpose

WAL recovery is the process of bringing the database to a consistent state after a crash or improper shutdown. Recovery uses the WAL to reapply committed transactions that may not have been fully persisted to the main database file.

## Types

### RecoveryState

**Description**: The current state of the recovery process

**Variants**:

**NotStarted**: Recovery has not begun
- Initial state when WAL is opened
- No records have been examined

**Scanning**: Reading and validating WAL records
- Actively scanning WAL file
- Building list of committed transactions

**CheckpointFound**: Checkpoint record located
- Found a valid checkpoint in WAL
- Can potentially skip earlier records

**Replaying**: Applying transactions to database
- WAL has been scanned successfully
- Now applying mutations to database

**Corrupted**: WAL corruption detected
- Invalid magic, checksum, or structure
- Recovery may continue from a safe point

**Recovered**: Recovery completed successfully
- All valid transactions applied
- Database is consistent

**Failed**: Recovery failed catastrophically
- Cannot recover any data
- Database may need to be recreated from backup

### RecoveryMode

**Description**: Strategy for handling WAL during recovery

**Variants**:

**FullRecovery**: Replay all records from beginning
- Safest mode, recovers all possible data
- Slowest, scans entire WAL
- Default mode after crash

**CheckpointRecovery**: Start from last checkpoint
- Requires checkpoint record exists
- Faster than full recovery
- May lose uncheckpointed data

**PartialRecovery**: Recover from specific LSN
- User specifies starting LSN
- Useful for selective recovery
- Advanced operation

### RecoveryResult

**Description**: Outcome of the recovery process

**Fields**:
- records_scanned: u64 - Total records examined during recovery
- records_replayed: u64 - Records successfully applied to database
- records_skipped: u64 - Records skipped (before checkpoint or corrupted)
- last_lsn: Lsn - The LSN of the last processed record
- checkpoint_lsn: Option<Lsn> - LSN of the checkpoint record (if found)
- database_state: DatabaseState - The state of the database after recovery
- duration_ms: u64 - Time taken for recovery
- error: Option<RecoveryError> - Error if recovery failed

**Invariants**:
- records_replayed <= records_scanned
- records_skipped = records_scanned - records_replayed
- last_lsn equals the highest LSN successfully processed
- checkpoint_lsn is None if no checkpoint was found

## Functions

### recover(mode: RecoveryMode) -> Result<RecoveryResult, RecoveryError>

**Purpose**: Perform WAL recovery and restore database to consistent state

**Parameters**:
- mode: RecoveryMode - The recovery strategy to use

**Returns**: RecoveryResult on success, RecoveryError on failure

**Algorithm**:

1. **Initialize recovery**:
   - Create RecoveryResult with default values
   - Record start time for duration tracking
   - Transition to Scanning state

2. **Open WAL file**:
   - Open WAL file in read-only mode
   - Get file size for bounds checking

3. **Scan WAL based on mode**:
   - Match on mode:
     - **FullRecovery**:
       - Set start_lsn = 1 (scan from beginning)
       - Scan all records in WAL

     - **CheckpointRecovery**:
       - Scan WAL to find checkpoint record
       - If checkpoint found at LSN N:
         - Set start_lsn = N + 1
       - If no checkpoint found:
         - Fall back to FullRecovery (start_lsn = 1)

     - **PartialRecovery**:
       - Use user-provided start_lsn
       - Validate start_lsn is valid (1 <= start_lsn <= highest LSN)

4. **Replay WAL records**:
   - Call replay_from(start_lsn) to get list of commit records
   - For each commit record returned:
     - Increment records_replayed counter
     - Store record for application

   - If replay fails with corruption:
     - Transition to Corrupted state
     - Note the position of corruption
     - May continue with partial recovery

5. **Apply transactions to database**:
   - Transition to Replaying state
   - For each commit record in order:
     - Create a new WriteTxn
     - For each mutation in commit record:
       - If Put: call txn.put(key, value)
       - If Delete: call txn.delete(key)
     - Call txn.commit() to apply changes to database
   - Sync database file after all transactions applied

6. **Handle checkpoint**:
   - If checkpoint_lsn was found:
     - Write new checkpoint record to WAL
     - Sync WAL
     - Truncate WAL to remove old records

7. **Finalize recovery**:
   - Transition to Recovered state
   - Set RecoveryResult fields:
     - records_scanned = total records examined
     - records_replayed = count of applied records
     - last_lsn = highest LSN processed
     - checkpoint_lsn = checkpoint LSN if found
     - database_state = Consistent
     - duration_ms = current_time - start_time
   - Return RecoveryResult

**Error conditions**:
- WalNotFound: WAL file does not exist (may be first run)
- CorruptedWAL: WAL is corrupted and unrecoverable
- DatabaseLocked: Database file is locked by another process
- OutOfMemory: Insufficient memory for recovery
- IoError: File I/O operation failed

**Concurrency**: Must be exclusive. No other operations during recovery.

**Duration**: O(N) where N is the number of records in WAL

### validateWalIntegrity() -> Result<bool, Error>

**Purpose**: Check if WAL file is structurally sound without applying changes

**Returns**: true if WAL is valid, false if corrupted

**Algorithm**:

1. **Scan WAL**:
   - For each record in WAL:
     - Validate header magic
     - Validate header checksum
     - Validate trailer magic
     - Validate trailer checksum
     - Validate payload checksum
     - Stop at first error

2. **Return result**:
   - If all records valid: return true
   - If any record invalid: return false

**Time complexity**: O(N) where N is the number of records

### findCheckpoint() -> Result<Option<Lsn>, Error>

**Purpose**: Scan WAL to find the most recent checkpoint record

**Returns**: LSN of checkpoint record, or None if no checkpoint found

**Algorithm**:

1. **Scan backwards** (optimization):
   - Start from end of WAL file
   - Scan backwards looking for checkpoint records
   - This is faster than scanning entire WAL

2. **If backwards scan fails**:
   - Fall back to forward scan
   - Scan from beginning, track highest checkpoint LSN

3. **Return result**:
   - Return LSN of most recent checkpoint
   - Return None if no checkpoint found

**Time complexity**: O(N) worst case, O(K) best case where K is distance from end to checkpoint

## Invariants

### Recovery Safety Invariants

- **Idempotent**: Running recovery multiple times produces same result
- **No double application**: Transactions are not applied twice
- **Atomic**: Either all transactions are applied or none are
- **Consistent**: After recovery, database is in a consistent state

### Checkpoint Invariants

- **Checkpoint before truncate**: WAL is truncated only after checkpoint
- **Checkpoint LSN tracked**: The checkpoint LSN is persisted for recovery
- **Checkpoint implies consistency**: Database file is consistent at checkpoint LSN

### Corruption Handling Invariants

- **Stop at corruption**: Recovery stops when corruption is detected
- **Partial recovery**: Valid records before corruption are recovered
- **No panic**: Corruption returns errors, never panics
- **Logged**: All corruption is logged for investigation

## Dependencies

- **Uses**: WAL replay, database write operations, file I/O
- **Used by**: Database open, crash recovery, manual recovery operations

## Rust Implementation Guidance

### Module Structure

The recovery functionality should be organized as:

```
northstar_core::wal::recovery
├── pub enum RecoveryState
├── pub enum RecoveryMode
├── pub struct RecoveryResult
├── pub enum RecoveryError
├── pub fn recover(
    wal: &mut WriteAheadLog,
    db: &mut Db,
    mode: RecoveryMode
) -> Result<RecoveryResult, RecoveryError>
└── impl WriteAheadLog
    └── pub fn recover(&mut self, mode: RecoveryMode) -> Result<RecoveryResult, WalError>
```

### Type Definitions

**RecoveryState enum**: Tracks recovery progress

```rust
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RecoveryState {
    NotStarted,
    Scanning,
    CheckpointFound,
    ReplayFailed,
    Recovered,
    Failed,
}
```

**RecoveryMode enum**: Recovery strategy

```rust
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RecoveryMode {
    Full,
    Checkpoint,
    Partial { start_lsn: Lsn },
}
```

**RecoveryResult struct**: Recovery outcome

```rust
#[derive(Debug)]
pub struct RecoveryResult {
    pub records_scanned: u64,
    pub records_replayed: u64,
    pub records_skipped: u64,
    pub last_lsn: Lsn,
    pub checkpoint_lsn: Option<Lsn>,
    pub database_state: DatabaseState,
    pub duration_ms: u64,
    pub error: Option<RecoveryError>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DatabaseState {
    Consistent,
    PartiallyRecovered,
    Corrupted,
    Empty,
}
```

**RecoveryError enum**: Recovery-specific errors

```rust
#[derive(Debug)]
pub enum RecoveryError {
    WalNotFound,
    CorruptedWal { position: usize, reason: String },
    DatabaseLocked,
    CheckpointNotFound,
    OutOfMemory,
    Io(std::io::Error),
}
```

### Key Decisions

**Recovery mode selection**: Use CheckpointRecovery by default for faster recovery. Fall back to FullRecovery if no checkpoint exists.

**Corruption handling**: Stop recovery at corruption point. Don't attempt to skip corrupted records and continue (too risky). Manual intervention may be needed.

**Database state after recovery**: Always leave database in consistent state. If recovery partially fails, database may be in PartiallyRecovered state requiring attention.

**Performance optimization**: Use mmap for large WAL files during recovery. This can significantly speed up scanning.

### Implementation Notes

**Step 1: Initialize recovery**
```rust
let start_time = Instant::now();
let mut result = RecoveryResult {
    records_scanned: 0,
    records_replayed: 0,
    records_skipped: 0,
    last_lsn: 0,
    checkpoint_lsn: None,
    database_state: DatabaseState::Empty,
    duration_ms: 0,
    error: None,
};
let state = RecoveryState::Scanning;
```

**Step 2: Determine start LSN based on mode**
```rust
let start_lsn = match mode {
    RecoveryMode::Full => 1,
    RecoveryMode::Checkpoint => {
        match self.find_checkpoint()? {
            Some(lsn) => lsn + 1,
            None => 1, // No checkpoint, start from beginning
        }
    }
    RecoveryMode::Partial { start_lsn } => start_lsn,
};
```

**Step 3: Replay WAL**
```rust
let replay_result = self.replay_from(start_lsn, allocator)?;

result.records_scanned = replay_result.last_lsn;
result.records_replayed = replay_result.commit_records.len() as u64;
result.last_lsn = replay_result.last_lsn;
result.checkpoint_lsn = replay_result.last_checkpoint_lsn;
```

**Step 4: Apply transactions**
```rust
state = RecoveryState::Replaying;

for commit_record in replay_result.commit_records {
    let mut txn = db.begin_write()?;
    for mutation in commit_record.mutations {
        match mutation {
            Mutation::Put { key, value } => txn.put(key, value)?,
            Mutation::Delete { key } => txn.delete(key)?,
        }
    }
    txn.commit()?;
}

db.sync()?;
```

**Step 5: Finalize**
```rust
state = RecoveryState::Recovered;
result.database_state = DatabaseState::Consistent;
result.duration_ms = start_time.elapsed().as_millis() as u64;

Ok(result)
```

**Step 6: Handle errors gracefully**
```rust
if let Err(e) = recovery_result {
    state = RecoveryState::Failed;
    result.error = Some(e);
    result.database_state = DatabaseState::Corrupted;
    return Err(e);
}
```

### Testing Strategy

**Unit tests needed for**:
- Recover from empty WAL
- Recover from WAL with single record
- Recover from WAL with multiple records
- Recover from WAL with checkpoint
- Recover from WAL with corruption (should handle gracefully)
- Recover with CheckpointMode when no checkpoint exists
- Recover with PartialMode with valid LSN
- Verify database state after recovery
- Verify recovery is idempotent

**Property tests for**:
- Recovery idempotency: running recovery twice produces same database state
- Checkpoint recovery: recovers same data as full recovery from checkpoint point
- Corruption handling: stops at corruption without crashing

**Integration scenarios**:
- Simulate crash during commit, verify recovery restores data
- Simulate crash during checkpoint, verify recovery handles partial checkpoint
- Large WAL recovery (millions of records) to test performance
- Concurrent recovery attempts (should fail or serialize)

### Recovery Performance

**Expected throughput**: Varies by hardware and record size
- Small records (1KB): 50,000-100,000 records/sec
- Large records (1MB): 100-1,000 records/sec
- Cached WAL: 2-5x faster than disk

**Optimization strategies**:
- Use mmap for WAL access (faster than pread)
- Batch database writes (multiple transactions per sync)
- Parallelize transaction application (if transactions are independent)
- Compress WAL during recovery (reduce I/O)

**Memory usage**:
- O(N) where N is the number of records
- Can be reduced by processing records incrementally
- Use memory-mapped file to reduce copies

### Recovery Checklist

Before attempting recovery:

- [ ] Verify WAL file exists and is readable
- [ ] Verify database file is not locked
- [ ] Check available disk space for recovery
- [ ] Backup existing database file (if it exists)
- [ ] Check available memory for recovery

During recovery:

- [ ] Monitor recovery progress
- [ ] Log any corruption found
- [ ] Track recovery rate (records/sec)
- [ ] Monitor memory usage

After recovery:

- [ ] Verify database is consistent
- [ ] Run database integrity checks
- [ ] Verify application can connect
- [ ] Update checkpoint
- [ ] Truncate WAL if appropriate
- [ ] Document recovery outcome

### Failure Scenarios

**Scenario 1: Crash during commit**
- WAL contains partial commit record
- Recovery detects incomplete record (checksum fails)
- Partial record is skipped
- Database recovers to state before crashed transaction

**Scenario 2: Crash during checkpoint**
- WAL contains checkpoint record
- Database file may be partially written
- Recovery replays all transactions up to checkpoint
- Database recovers to checkpoint state

**Scenario 3: WAL corruption**
- WAL has corrupted records
- Recovery stops at corruption point
- Records before corruption are recovered
- Records after corruption are lost
- Manual intervention may be needed

**Scenario 4: No WAL file**
- WAL file does not exist (first run or deleted)
- Database starts with empty state
- No recovery needed
- New WAL file is created

**Scenario 5: WAL and database out of sync**
- WAL has records not reflected in database
- Recovery replays all WAL records
- Database is brought up to date
- Checkpoint is created
- WAL is truncated

### Recovery Monitoring

Key metrics to track during recovery:

- **Progress percentage**: (records_replayed / records_scanned) * 100
- **Throughput**: records_replayed / elapsed_time
- **Estimated time remaining**: (records_remaining / throughput)
- **Memory usage**: current memory consumption
- **Disk I/O**: read/write bytes per second

Example output:
```
Recovery Progress:
  State: Replaying
  Records: 1,234,567 / 5,000,000 (24.7%)
  Throughput: 45,678 records/sec
  ETA: 82 seconds
  Memory: 256 MB
  Disk I/O: 125 MB/sec read, 12 MB/sec write
```
