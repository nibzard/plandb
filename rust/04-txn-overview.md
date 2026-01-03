# Transaction System Overview

## Purpose

The Transaction System provides ACID guarantees for database operations. It manages the lifecycle of transactions, tracks mutations, coordinates two-phase commit with the WAL, and ensures isolation between concurrent operations.

## ACID Guarantees

### Atomicity

**Definition**: All operations in a transaction succeed or none do.

**Implementation**:
- Mutations are tracked in memory during transaction
- On commit, all mutations are written to WAL as a single record
- WAL provides atomic append guarantee
- If crash occurs before WAL sync, transaction is not applied
- During recovery, either all mutations are replayed or none are

**What is atomic**:
- Each Put and Delete operation
- The entire commit (all mutations in transaction)
- The two-phase commit process

### Consistency

**Definition**: Database transitions from one valid state to another.

**Implementation**:
- All mutations are validated before being applied
- B+tree invariants are maintained
- Foreign key constraints (future feature)
- User-defined constraints (future feature)

**Validation checks**:
- Key size limits (4KB max)
- Value size limits (16MB max)
- Operation count limits (1000 per commit)
- Checksum validation on recovery

### Isolation

**Definition**: Concurrent transactions do not interfere with each other.

**Implementation (V0)**:
- Single writer at a time (write lock on entire database)
- Multiple readers can proceed concurrently
- Read-your-writes: A transaction sees its own mutations
- Snapshot isolation: Readers see consistent snapshot at start of read transaction

**Isolation level (V0)**:
- Read Committed with snapshot semantics
- Writers are serialized (no concurrent writes)
- Future versions may add full serializability

### Durability

**Definition**: Once a transaction commits, its changes persist even after crash.

**Implementation**:
- All mutations are written to WAL before commit returns
- WAL is synced (fsync) before commit completes
- After WAL write, mutations are applied to main database
- Crash recovery replays WAL to restore committed transactions

**Durability guarantees**:
- Committed transactions survive process crash
- Committed transactions survive power loss
- Committed transactions survive file system crashes

## Transaction Types

### ReadTxn

**Description**: Read-only transaction with consistent snapshot

**Characteristics**:
- Does not modify data
- Sees consistent snapshot as of transaction start
- Multiple readers can proceed concurrently
- Never conflicts with other readers
- May block waiting for writer to complete

**Operations**:
- get(key): Read a value from the database
- scan(start, end): Iterate over key range
- Snapshot is captured at transaction begin

**Lifetime**: From begin() to explicit close() or scope end

### WriteTxn

**Description**: Read-write transaction with mutation tracking

**Characteristics**:
- Can modify data (Put, Delete)
- Tracks all mutations in memory
- Exclusive write access (no concurrent writers)
- Sees its own mutations (read-your-writes)
- Two-phase commit protocol

**Operations**:
- get(key): Read a value
- put(key, value): Insert or update a key-value pair
- delete(key): Remove a key from database
- prepare(): First phase of commit
- commit(): Second phase of commit
- rollback(): Abort transaction

**Lifetime**: From begin() to commit/rollback

## Transaction Lifecycle

### State Machine

**States**:
1. **Active**: Transaction is started and can accept operations
2. **Preparing**: First phase of commit, mutations are being written to WAL
3. **Committed**: Transaction has successfully committed
4. **Aborted**: Transaction was rolled back

**Valid transitions**:
- Active → Preparing (on prepare() call)
- Preparing → Committed (on commit() call)
- Active → Aborted (on rollback() call)
- Preparing → Aborted (on error during commit)

**Invalid transitions**:
- Committed → Any other state (committed is terminal)
- Aborted → Any other state (aborted is terminal)
- Active → Committed (must go through Preparing first)

### State Transitions Diagram

```
     begin()
        |
        v
    [Active] ────── put() / delete() / get()
        |
        | prepare()
        v
  [Preparing] ──── write to WAL
        |             |
        | commit()    | error
        v             v
  [Committed]    [Aborted]
        |
      close()
```

## Core Components

### TransactionContext

**Description**: Tracks all state for an active transaction

**Fields**:
- txn_id: u64 - Unique transaction identifier
- parent_txn_id: u64 - Parent transaction ID (for nested transactions, 0 for top-level)
- state: TransactionState - Current state in lifecycle
- mutations: ArrayList<Mutation> - All Put and Delete operations
- allocated_pages: ArrayList<u64> - Pages allocated during transaction
- modified_pages: HashMap<u64, []u8> - Before images for rollback
- timestamp_ns: u64 - Transaction start timestamp

**Invariants**:
- txn_id is unique among all active transactions
- state transitions follow valid state machine
- mutations contain all operations in transaction order
- modified_pages contain before images for all modified pages

### Mutation

**Description**: Represents a single database operation

**Variants**:
- **Put**: Insert or update a key-value pair
  - key: []u8 - The key to insert/update
  - value: []u8 - The value to associate with key
- **Delete**: Remove a key from database
  - key: []u8 - The key to delete

**Invariants**:
- Put must have non-empty key and non-empty value
- Delete must have non-empty key
- Keys are owned (copied into transaction context)

### CommitRecord

**Description**: Serializable representation of a committed transaction

**Fields**:
- txn_id: u64 - Transaction identifier
- root_page_id: u64 - New B+tree root after applying mutations
- mutations: []Mutation - All operations in transaction
- checksum: u32 - CRC32C checksum of mutations

**Purpose**:
- Written to WAL for durability
- Used during crash recovery
- Enables replay of transaction effects

## Two-Phase Commit

### Phase 1: Prepare

1. **Validate transaction**:
   - Check that transaction is in Active state
   - Validate all mutations (size limits, checksums)
   - Verify no constraint violations

2. **Write to WAL**:
   - Create CommitRecord from transaction context
   - Calculate checksum
   - Append CommitRecord to WAL
   - Sync WAL to disk

3. **Transition state**:
   - Change state from Active to Preparing
   - No more mutations allowed

### Phase 2: Commit

1. **Apply to database**:
   - For each mutation in order:
     - Apply to B+tree structure
     - Update pages in pager
   - Write modified pages to database file

2. **Sync database file**:
   - Ensure all pages are durably persisted
   - Database is now consistent at new state

3. **Transition state**:
   - Change state from Preparing to Committed
   - Release transaction resources

4. **Truncate WAL** (optional):
   - After checkpoint, old WAL records can be removed
   - Frees disk space

## Concurrency Model

### Readers

- **Multiple readers**: Can proceed concurrently
- **Shared lock**: Acquire shared lock on database
- **Snapshot isolation**: Each reader sees consistent snapshot
- **No blocking**: Readers don't block other readers

### Writers

- **Single writer**: Only one write transaction at a time
- **Exclusive lock**: Acquire exclusive lock on database
- **Serialization**: Writes are totally ordered
- **Blocks readers**: May block waiting for readers to complete

### Read-Write Coordination

- **Writer waits for readers**: Active readers must finish before writer can commit
- **Readers wait for writer**: New readers wait for active writer to complete
- **Fairness**: FIFO ordering to prevent starvation

## Public API

### Database Operations

```rust
impl Db {
    // Begin read transaction
    pub fn begin_read(&self) -> Result<ReadTxn, Error>;

    // Begin write transaction
    pub fn begin_write(&self) -> Result<WriteTxn, Error>;
}
```

### Read Transaction

```rust
impl ReadTxn {
    // Get value for key
    pub fn get(&self, key: &[u8]) -> Result<Option<Value>, Error>;

    // Scan key range
    pub fn scan(&self, start: &[u8], end: &[u8]) -> Result<ScanIterator, Error>;

    // Close transaction
    pub fn close(self) -> Result<(), Error>;
}
```

### Write Transaction

```rust
impl WriteTxn {
    // Get value for key (reads own writes)
    pub fn get(&self, key: &[u8]) -> Result<Option<Value>, Error>;

    // Insert or update key-value pair
    pub fn put(&mut self, key: &[u8], value: &[u8]) -> Result<(), Error>;

    // Delete key from database
    pub fn delete(&mut self, key: &[u8]) -> Result<(), Error>;

    // Prepare for commit (phase 1)
    pub fn prepare(&mut self) -> Result<(), Error>;

    // Commit transaction (phase 2)
    pub fn commit(self) -> Result<(), Error>;

    // Rollback transaction
    pub fn rollback(self) -> Result<(), Error>;
}
```

## Dependencies

- **Uses**: WAL module, Pager module, B+tree module
- **Used by**: Public database API, application code

## Rust Implementation Guidance

### Module Structure

```
northstar_core::txn
├── pub enum TransactionState
├── pub enum Mutation
├── pub struct CommitRecord
├── pub struct TransactionContext
├── pub struct ReadTxn
├── pub struct WriteTxn
└── impl TransactionContext
    ├── pub fn new(allocator, txn_id, parent_id) -> Self
    ├── pub fn put(&mut self, key, value) -> Result<(), Error>
    ├── pub fn delete(&mut self, key) -> Result<(), Error>
    ├── pub fn prepare(&mut self) -> Result<(), Error>
    ├── pub fn commit(self) -> Result<(), Error>
    ├── pub fn rollback(self) -> Result<(), Error>
    └── pub fn create_commit_record(&self, root_page_id) -> CommitRecord
```

### Type Definitions

**TransactionState**: Enum with strict state transitions

```rust
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TransactionState {
    Active,
    Preparing,
    Committed,
    Aborted,
}
```

**Mutation**: Enum representing database operations

```rust
#[derive(Debug, Clone)]
pub enum Mutation {
    Put { key: Vec<u8>, value: Vec<u8> },
    Delete { key: Vec<u8> },
}

impl Mutation {
    pub fn get_key(&self) -> &[u8] {
        match self {
            Mutation::Put { key, .. } => key,
            Mutation::Delete { key } => key,
        }
    }
}
```

**CommitRecord**: Struct for WAL persistence

```rust
#[derive(Debug)]
pub struct CommitRecord {
    pub txn_id: u64,
    pub root_page_id: u64,
    pub mutations: Vec<Mutation>,
    pub checksum: u32,
}
```

### Key Decisions

**Transaction ID allocation**: Use atomic counter for unique IDs. Initialize to 1, increment for each new transaction.

**Mutation ownership**: Transaction owns the mutations (Vec<Mutation>). Keys and values are copied into transaction context.

**Error handling**: Use Result types throughout. Never panic on user input. Only panic on internal bugs.

**Locking strategy**: Use RwLock for database access. Writers acquire write lock, readers acquire read lock.

### Testing Strategy

**Unit tests needed for**:
- Create transaction, verify state is Active
- Put operation in active transaction
- Delete operation in active transaction
- Prepare transaction, verify state transitions to Preparing
- Commit transaction, verify state transitions to Committed
- Rollback transaction, verify state transitions to Aborted
- Invalid state transitions return errors
- Read transaction cannot write

**Property tests for**:
- Transaction ID uniqueness
- Mutation order preservation
- State transition validity

**Integration scenarios**:
- Multiple concurrent read transactions
- Single writer blocks new readers
- Transaction commit persists across restart
- Transaction rollback discards changes
