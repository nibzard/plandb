# TransactionContext

## Purpose

TransactionContext is the central state structure that tracks all information for an active transaction in NorthstarDB. It accumulates mutations, tracks allocated and modified pages, maintains transaction lifecycle state, and provides the context needed for two-phase commit, rollback, and recovery. TransactionContext ensures atomicity by buffering all changes until commit, enables rollback through before-images, and supports MVCC through transaction ID assignment.

## Core Structure

### TransactionContext

**Description**: Primary structure tracking all state for a transaction from begin through commit or rollback. TransactionContext owns the mutations, page tracking, and metadata needed to manage the transaction lifecycle.

**Lifetime**: From transaction begin until transaction completion (commit or rollback)

**Ownership**: TransactionContext owns its data (mutations, page lists, before-images) and is responsible for cleaning up these resources when dropped or rolled back

## Fields

### Identity Fields

#### txn_id: TransactionId

**Type**: TransactionId (newtype wrapper around u64)

**Purpose**: Unique identifier for this transaction among all transactions in the database

**Allocation**: Assigned at transaction begin from a global monotonic counter

**Uniqueness**: Guaranteed to be unique among all active and committed transactions

**Usage**:
- MVCC visibility calculations
- WAL record association
- Recovery identification
- Conflict detection

**Invariants**:
- txn_id is allocated atomically from a global counter
- txn_id never changes during transaction lifetime
- txn_id values are strictly increasing over time
- txn_id 0 is reserved (not used for actual transactions)
- After commit, txn_id is permanently associated with this transaction

#### parent_txn_id: TransactionId

**Type**: TransactionId (newtype wrapper around u64)

**Purpose**: Identifies the parent transaction for nested transactions (0 if top-level)

**Current Implementation**: V0 does not support nested transactions, this field is always 0

**Future Usage**: Reserved for savepoints and nested transaction support

**Invariants**:
- parent_txn_id is always 0 in V0 (no nesting)
- For nested transactions (future), parent_txn_id < txn_id
- parent_txn_id must reference a committed or active transaction

#### state: TransactionState

**Type**: TransactionState enum (Active, Preparing, Committed, Aborted)

**Purpose**: Tracks current position in transaction lifecycle state machine

**Valid States**:
- **Active**: Transaction is accepting mutations and reads
- **Preparing**: First phase of commit, mutations written to WAL
- **Committed**: Transaction successfully committed, terminal state
- **Aborted**: Transaction rolled back, terminal state

**State Transitions**:
- Active → Preparing (on prepare() call)
- Preparing → Committed (on commit() call)
- Active → Aborted (on rollback() call)
- Preparing → Aborted (on error during commit)

**Invariants**:
- State transitions follow the valid state machine
- Once in Committed or Aborted state, cannot transition out
- Mutations only accepted in Active state
- prepare() only valid in Active state
- commit() only valid in Preparing state
- rollback() valid in Active or Preparing states

### Mutation Tracking

#### mutations: Vec<Mutation>

**Type**: Vector of Mutation enum instances

**Purpose**: Ordered collection of all Put and Delete operations in this transaction

**Ordering**: Mutations are stored in the order they were issued by the application

**Ownership**: TransactionContext owns the mutations (Vec<Mutation> with owned Vec<u8> data)

**Capacity**: Grows dynamically as mutations are added

**Usage**:
- Buffer changes until commit
- Serialize to WAL during prepare phase
- Apply to B+tree during commit phase
- Validate before commit

**Invariants**:
- mutations list contains all operations in transaction order
- Each mutation is either Put or Delete variant
- All mutations share the same txn_id
- mutations list is immutable during Preparing/Committed/Aborted states
- mutations list is cleared on rollback or after commit
- Maximum mutations per transaction: 1000 (configurable limit)

#### mutation_count: usize

**Type**: usize (platform-dependent, usually 64-bit)

**Purpose**: Number of mutations currently in the mutations vector

**Optimization**: Avoid repeated mutations.len() calls in hot paths

**Invariants**:
- mutation_count equals mutations.len() at all times
- mutation_count is incremented immediately when mutation is added
- mutation_count is checked against MAX_OPERATIONS_PER_COMMIT before adding

### Page Tracking

#### allocated_pages: Vec<PageId>

**Type**: Vector of PageId instances

**Purpose**: Tracks all pages allocated during this transaction for cleanup on rollback

**Ownership**: TransactionContext owns the page IDs

**Ordering**: Pages are stored in allocation order

**Usage**:
- Free allocated pages if transaction rolls back
- Track which pages need to be written during commit
- Recovery can identify pages allocated by uncommitted transactions

**Invariants**:
- allocated_pages contains all pages allocated by this transaction
- Pages are added to allocated_pages immediately after allocation
- On rollback, all pages in allocated_pages are freed
- On commit, allocated_pages is cleared (pages become part of database)
- No duplicate PageId entries in allocated_pages

#### modified_pages: HashMap<PageId, Vec<u8>>

**Type**: HashMap mapping PageId to byte vectors (page contents)

**Purpose**: Stores before-images of pages modified during transaction for rollback

**Ownership**: TransactionContext owns the before-image data

**Storage**: Full page contents copied before modification

**Usage**:
- Rollback: Restore original page contents from before-images
- Recovery: Identify dirty pages from crashed transactions
- Debugging: Inspect what changes were made

**Invariants**:
- modified_pages contains entry for each page modified in transaction
- Each entry stores complete page contents as they existed before modification
- Before-image is captured BEFORE page is modified
- On rollback, each page in modified_pages is restored from its before-image
- On commit, modified_pages is discarded (changes are already applied)
- No entry exists for pages that were only read, not modified

**Memory Usage**: Each modified page consumes PAGE_SIZE bytes (typically 4KB or 8KB) in modified_pages

### Timing and Diagnostics

#### start_timestamp_ns: u64

**Type**: u64 (64-bit unsigned integer)

**Purpose**: Nanosecond-precision timestamp when transaction began

**Time Source**: System clock or monotonic clock (implementation choice)

**Usage**:
- Transaction duration tracking
- Performance monitoring and profiling
- Debugging long-running transactions
- Timeout detection (future feature)

**Invariants**:
- start_timestamp_ns is captured once at transaction begin
- start_timestamp_ns never changes during transaction lifetime
- Transaction duration = current_timestamp - start_timestamp_ns
- For committed transactions, duration = commit_timestamp - start_timestamp_ns

#### commit_lsn: Option<Lsn>

**Type**: Option<Lsn> (Log Sequence Number)

**Purpose**: WAL position where this transaction's commit record was written

**Value**: None before commit, Some(Lsn) after successful WAL write

**Usage**:
- Link transaction to its WAL record
- Recovery: Find commit record to rebuild transaction state
- Checkpointing: Determine which WAL records can be truncated
- Debugging: Trace transaction through WAL

**Invariants**:
- commit_lsn is None in Active and Aborted states
- commit_lsn is Some(Lsn) in Preparing and Committed states
- commit_lsn is set after WAL append completes successfully
- All mutations in transaction are contiguous in WAL starting at commit_lsn
- commit_lsn monotonically increases as transactions commit

### Allocator Reference

#### allocator: Allocator

**Type**: Memory allocator (Zig-specific, Rust uses standard allocator)

**Purpose**: Memory allocator for all transaction context allocations

**Usage**:
- Allocate mutations vector
- Allocate page tracking structures
- Allocate before-image buffers
- All TransactionContext memory comes from this allocator

**Invariants**:
- allocator is provided at transaction creation
- All allocations use this allocator consistently
- allocator outlives the TransactionContext
- On drop, all allocated memory is freed to this allocator

## State Machine Details

### Active State

**Description**: Initial state after transaction begin. Accepting mutations and reads.

**Valid Operations**:
- put(key, value): Add mutation to mutations list
- delete(key): Add mutation to mutations list
- get(key): Read from database with write-your-own-writes
- prepare(): Begin commit process, transition to Preparing
- rollback(): Abort transaction, transition to Aborted

**Invalid Operations**:
- commit(): Must call prepare() first
- Any mutation after prepare(): Must be in Active state

**Invariants**:
- state field equals TransactionState::Active
- mutations list can grow
- allocated_pages can grow
- modified_pages can grow
- commit_lsn is None
- Transaction can transition to Preparing or Aborted

### Preparing State

**Description**: First phase of two-phase commit. Mutations written to WAL.

**Valid Operations**:
- commit(): Complete commit, transition to Committed
- rollback(): Abort even after WAL write, transition to Aborted

**Invalid Operations**:
- put(), delete(), get(): No operations allowed in Preparing state
- prepare(): Already in Preparing state

**Invariants**:
- state field equals TransactionState::Preparing
- mutations list is immutable (no more mutations allowed)
- commit_lsn is Some(Lsn) (WAL write succeeded)
- WAL contains complete commit record at commit_lsn
- Transaction can transition to Committed or Aborted

### Committed State

**Description**: Terminal state after successful commit. Changes durable and visible.

**Valid Operations**:
- None (terminal state)

**Invariants**:
- state field equals TransactionState::Committed
- mutations list may be discarded (already applied to database)
- allocated_pages is cleared (pages now part of database)
- modified_pages is discarded (changes applied)
- commit_lsn is Some(Lsn)
- Transaction cannot transition out of Committed state
- Transaction resources are being released

### Aborted State

**Description**: Terminal state after rollback. All changes discarded.

**Valid Operations**:
- None (terminal state)

**Invariants**:
- state field equals TransactionState::Aborted
- mutations list is discarded
- allocated_pages is freed (pages returned to free list)
- modified_pages is used to restore page contents, then discarded
- commit_lsn is None (WAL record written but ignored during recovery)
- Transaction cannot transition out of Aborted state
- Transaction resources are being released

## Memory Management

### Mutation Ownership

**Owned Data**: TransactionContext owns all mutation data
- mutations: Vec<Mutation> where each Mutation owns its key/value Vec<u8>
- All key and value bytes are copied into transaction context
- No borrowed data from application
- Safe to store and use after application buffers are freed

**Memory Allocation**:
- Each Put mutation allocates Vec for key and value
- Each Delete mutation allocates Vec for key
- mutations vector grows as needed
- Allocator tracks all allocations

### Page Before-Images

**Copy-on-Write**: Before-images captured before page modification
- Full page copy (PAGE_SIZE bytes, typically 4KB or 8KB)
- Stored in HashMap for O(1) lookup by PageId
- Allocates new Vec<u8> for each modified page

**Memory Usage**:
- Each modified page: PAGE_SIZE bytes in modified_pages
- 100 modified pages at 4KB each = 400KB
- 1000 modified pages at 4KB each = 4MB
- Trade-off: Memory usage vs rollback ability

**Cleanup**:
- On commit: modified_pages dropped, memory freed
- On rollback: Before-images used to restore pages, then dropped

### Resource Cleanup

**On Commit**:
- mutations vector dropped (mutations applied to database)
- allocated_pages vector dropped (pages now owned by database)
- modified_pages HashMap dropped (changes already applied)
- TransactionContext itself dropped

**On Rollback**:
- mutations vector dropped (mutations discarded)
- Each PageId in allocated_pages freed to page free list
- Each page in modified_pages restored from before-image
- modified_pages HashMap dropped
- TransactionContext dropped

## Thread Safety

### Single-Threaded Usage (V0)

**Current Design**: TransactionContext is not thread-safe
- Designed for single-threaded or single-owner usage
- No interior locking or atomic operations
- Cannot be shared between threads directly

**Rationale**:
- V0 has single-writer design anyway
- Simplifies implementation
- No locking overhead
- Clear ownership semantics

### Multi-Threaded Future (Post-V0)

**Potential Approaches**:
- Wrap TransactionContext in Mutex for shared mutable access
- Use message passing for cross-thread mutations
- Per-thread transaction contexts with coordination

**Current Guidance**: Do not share TransactionContext across threads in V0

## Functions and Operations

### Construction

**new(allocator: Allocator, txn_id: TransactionId, parent_txn_id: TransactionId) -> Self**

Purpose: Create a new TransactionContext in Active state

Parameters:
- allocator: Memory allocator for all allocations
- txn_id: Unique transaction ID allocated from global counter
- parent_txn_id: Parent transaction ID (always 0 in V0)

Returns: Initialized TransactionContext

Initialization:
- Set state to TransactionState::Active
- Initialize empty mutations vector
- Initialize empty allocated_pages vector
- Initialize empty modified_pages HashMap
- Capture start_timestamp_ns from system clock
- Set commit_lsn to None

### Mutation Operations

**put(&mut self, key: &[u8], value: &[u8]) -> Result<(), Error>**

Purpose: Add a Put mutation to the transaction

Parameters:
- key: Key bytes to insert or update
- value: Value bytes to associate with key

Validation:
- Check state is Active
- Check mutation_count < MAX_OPERATIONS_PER_COMMIT
- Validate key length <= MAX_KEY_SIZE
- Validate value length <= MAX_VALUE_SIZE
- Validate key is non-empty

Effects:
- Copy key bytes into new Vec<u8>
- Copy value bytes into new Vec<u8>
- Create Mutation::Put { key, value }
- Append mutation to mutations vector
- Increment mutation_count

Returns: Ok(()) on success, Error on validation failure

**delete(&mut self, key: &[u8]) -> Result<(), Error>**

Purpose: Add a Delete mutation to the transaction

Parameters:
- key: Key bytes to delete

Validation:
- Check state is Active
- Check mutation_count < MAX_OPERATIONS_PER_COMMIT
- Validate key length <= MAX_KEY_SIZE
- Validate key is non-empty

Effects:
- Copy key bytes into new Vec<u8>
- Create Mutation::Delete { key }
- Append mutation to mutations vector
- Increment mutation_count

Returns: Ok(()) on success, Error on validation failure

### Page Tracking Operations

**track_allocated_page(&mut self, page_id: PageId)**

Purpose: Record a page allocated during this transaction

Parameters:
- page_id: ID of the newly allocated page

Effects:
- Append page_id to allocated_pages vector
- No duplicates checking (caller ensures uniqueness)

**track_modified_page(&mut self, page_id: PageId, before_image: Vec<u8>)**

Purpose: Store before-image of a page before modification

Parameters:
- page_id: ID of the page being modified
- before_image: Complete page contents before modification

Effects:
- Insert (page_id, before_image) into modified_pages HashMap
- Overwrites any existing entry (should not happen)

### State Transition Operations

**prepare(&mut self, wal: &mut Wal) -> Result<(), Error>**

Purpose: First phase of commit, write mutations to WAL

Parameters:
- wal: Mutable reference to WAL for appending commit record

Validation:
- Check state is Active
- Validate all mutations
- Check mutation_count > 0 (transactions with no mutations are no-ops)

Effects:
- Create CommitRecord from mutations and txn_id
- Calculate checksum
- Append CommitRecord to WAL
- Sync WAL to disk
- Set commit_lsn to LSN of commit record
- Transition state to Preparing
- Freeze mutations (no more mutations allowed)

Returns: Ok(()) on success, Error on WAL or validation failure

**commit(&mut self, pager: &mut Pager) -> Result<(), Error>**

Purpose: Second phase of commit, apply mutations to database

Parameters:
- pager: Mutable reference to Pager for applying changes

Validation:
- Check state is Preparing
- Verify commit_lsn is Some

Effects:
- For each mutation in mutations:
  - Apply mutation to B+tree structure
  - Update pages in pager
- Write all modified pages to database file
- Sync database file to disk
- Update meta page with new root_page_id and txn_id
- Transition state to Committed
- Release resources (mutations, allocated_pages, modified_pages)

Returns: Ok(()) on success, Error on B+tree or pager failure

**rollback(&mut self, pager: &mut Pager)**

Purpose: Abort transaction and undo all changes

Parameters:
- pager: Mutable reference to Pager for cleanup

Effects:
- For each (page_id, before_image) in modified_pages:
  - Restore page contents from before_image
  - Write restored page to database file
- For each page_id in allocated_pages:
  - Free page back to pager free list
- Transition state to Aborted
- Release all resources (mutations, allocated_pages, modified_pages)
- commit_lsn remains None (WAL record ignored during recovery)

Returns: None (rollback always succeeds)

### Query Operations

**get(&self, pager: &Pager, key: &[u8]) -> Result<Option<Value>, Error>**

Purpose: Read a value, seeing own writes if applicable

Parameters:
- pager: Reference to Pager for B+tree access
- key: Key to look up

Algorithm:
- Check mutations in reverse order (most recent first)
- If Put mutation found for key, return its value
- If Delete mutation found for key, return None
- Otherwise, perform B+tree lookup in pager
- Return found value or None

Returns: Some(Value) if key exists, None if not found

**mutation_count(&self) -> usize**

Purpose: Get number of mutations in transaction

Returns: Current mutation count

**is_active(&self) -> bool**

Purpose: Check if transaction is in Active state

Returns: true if state is Active, false otherwise

**is_preparing(&self) -> bool**

Purpose: Check if transaction is in Preparing state

Returns: true if state is Preparing, false otherwise

**is_committed(&self) -> bool**

Purpose: Check if transaction is in Committed state

Returns: true if state is Committed, false otherwise

**is_aborted(&self) -> bool**

Purpose: Check if transaction is in Aborted state

Returns: true if state is Aborted, false otherwise

## Invariants

### State Invariants

- **State Machine Compliance**: State transitions only follow valid transitions
- **Terminal States**: Committed and Aborted are terminal, no transitions out
- **Mutation Acceptance**: Mutations only accepted in Active state
- **Commit LSN**: commit_lsn is Some only in Preparing and Committed states

### Identity Invariants

- **Unique txn_id**: No two active transactions have the same txn_id
- **Immutable txn_id**: txn_id never changes after allocation
- **Parent Ordering**: parent_txn_id < txn_id (for nested transactions, future)
- **V0 No Nesting**: parent_txn_id is always 0 in V0

### Mutation Invariants

- **Ordered Mutations**: mutations list preserves operation order
- **Mutation Ownership**: TransactionContext owns all mutation data
- **No Duplicate Mutations**: Application may issue duplicate puts/deletes, all recorded
- **Mutation Count**: mutation_count equals mutations.len()
- **Maximum Mutations**: mutation_count <= MAX_OPERATIONS_PER_COMMIT

### Page Tracking Invariants

- **Allocated Pages Accuracy**: allocated_pages contains exactly pages allocated by this transaction
- **Before-Image Accuracy**: modified_pages contains before-images of all modified pages
- **Before-Image Timing**: Before-images captured BEFORE page modification
- **No Missing Before-Images**: Every modified page has entry in modified_pages
- **Page Ownership**: Pages in allocated_pages owned by transaction until commit

### Memory Management Invariants

- **Allocator Validity**: allocator outlives TransactionContext
- **Owned Data**: No borrowed data in TransactionContext
- **Cleanup on Drop**: All resources freed when TransactionContext dropped
- **No Memory Leaks**: All allocations tracked and freed

### Thread Safety Invariants (V0)

- **No Concurrent Access**: TransactionContext not shared between threads
- **Single Writer**: Only one thread accesses TransactionContext
- **No Interior Mutability**: All mutations through &mut self

## Error Conditions

### Validation Errors

**TooManyMutations**: Mutation count exceeds MAX_OPERATIONS_PER_COMMIT
- When: Application attempts to add mutation beyond limit
- Effect: put() or delete() returns Error
- Recovery: Application must commit or rollback and start new transaction

**KeyTooLarge**: Key size exceeds MAX_KEY_SIZE
- When: Application attempts to put or delete oversized key
- Effect: put() or delete() returns Error
- Recovery: Application must use smaller key

**ValueTooLarge**: Value size exceeds MAX_VALUE_SIZE
- When: Application attempts to put oversized value
- Effect: put() returns Error
- Recovery: Application must use smaller value

**KeyEmpty**: Key has zero length
- When: Application attempts to put or delete empty key
- Effect: put() or delete() returns Error
- Recovery: Application must use non-empty key

### State Errors

**InvalidStateTransition**: Attempt to transition from invalid state
- When: prepare() called in Preparing state, commit() in Active state, etc.
- Effect: Operation returns Error
- Recovery: Application must check state before operation

**MutationAfterPrepare**: Attempt to add mutation after prepare()
- When: put() or delete() called in Preparing or Committed state
- Effect: Operation returns Error
- Recovery: Application must commit or rollback and start new transaction

### Resource Errors

**AllocationFailed**: Memory allocation failed
- When: Out of memory during mutation or page tracking
- Effect: Operation returns Error
- Recovery: Application must rollback and free memory

**WalAppendFailed**: WAL write or sync failed
- When: Disk error during prepare phase
- Effect: prepare() returns Error, transaction remains Active
- Recovery: Application can rollback or retry prepare

**BtreeApplyFailed**: B+tree operation failed during commit
- When: B+tree error, page allocation failure
- Effect: commit() returns Error, transaction in Preparing state
- Recovery: Application must rollback (WAL record ignored during recovery)

## Relationships to Other Types

### TransactionContext vs Mutation

**Composition**: TransactionContext contains multiple Mutations
- TransactionContext owns a Vec<Mutation>
- Each Mutation represents one operation
- TransactionContext provides grouping and atomicity

**Lifecycle**: Mutations live within TransactionContext
- Mutations created when put()/delete() called
- Mutations serialized to WAL during prepare()
- Mutations applied to B+tree during commit()
- Mutations freed when TransactionContext dropped

### TransactionContext vs CommitRecord

**Transformation**: TransactionContext converts to CommitRecord for WAL
- CommitRecord is serializable representation
- Contains txn_id, mutations, checksum
- Created from TransactionContext during prepare()
- Written to WAL for durability

**Differences**:
- TransactionContext: In-memory state with page tracking
- CommitRecord: Serializable subset for WAL persistence

### TransactionContext vs Pager

**Interaction**: TransactionContext tracks pager operations
- allocated_pages: Pages allocated from pager
- modified_pages: Before-images of pager pages
- commit() applies changes to pager
- rollback() restores pager state

**Separation of Concerns**:
- TransactionContext: Transaction logic and state
- Pager: Page allocation, I/O, caching

### TransactionContext vs WAL

**Durability**: TransactionContext uses WAL for commit
- prepare() writes commit record to WAL
- commit_lsn links TransactionContext to WAL position
- Recovery uses WAL to rebuild committed state

**Coordination**:
- WAL provides atomic append guarantee
- TransactionContext provides transaction semantics
- Together provide ACID durability

## Dependencies

- **Uses**:
  - TransactionId type (identifier)
  - Mutation type (operations)
  - TransactionState type (lifecycle)
  - PageId type (page tracking)
  - LSN type (WAL position)
  - Error types module (error handling)

- **Used By**:
  - WriteTxn (wraps TransactionContext)
  - Transaction begin/commit logic
  - Recovery (rebuild transaction state from WAL)
  - Testing (verify transaction behavior)

## Rust Implementation Guidance

### Module Structure

TransactionContext should be defined in transaction module:
```rust
// northstar_core::txn
pub struct TransactionContext {
    // fields...
}

impl TransactionContext {
    // methods...
}
```

### Type Definition

**Basic Structure**:
```rust
use std::collections::HashMap;
use crate::types::{TransactionId, PageId, Lsn};
use crate::txn::{Mutation, TransactionState};

pub struct TransactionContext {
    // Identity
    pub txn_id: TransactionId,
    pub parent_txn_id: TransactionId,
    pub state: TransactionState,

    // Mutations
    pub mutations: Vec<Mutation>,
    pub mutation_count: usize,

    // Page tracking
    pub allocated_pages: Vec<PageId>,
    pub modified_pages: HashMap<PageId, Vec<u8>>,

    // Timing and diagnostics
    pub start_timestamp_ns: u64,
    pub commit_lsn: Option<Lsn>,
}
```

### Constructor

**New TransactionContext**:
```rust
impl TransactionContext {
    pub fn new(txn_id: TransactionId) -> Self {
        Self {
            txn_id,
            parent_txn_id: TransactionId::INITIAL,
            state: TransactionState::Active,
            mutations: Vec::new(),
            mutation_count: 0,
            allocated_pages: Vec::new(),
            modified_pages: HashMap::new(),
            start_timestamp_ns: get_timestamp_ns(),
            commit_lsn: None,
        }
    }
}
```

### Mutation Operations

**Put Operation**:
```rust
impl TransactionContext {
    pub fn put(&mut self, key: &[u8], value: &[u8]) -> Result<(), Error> {
        // Check state
        if self.state != TransactionState::Active {
            return Err(Error::InvalidState);
        }

        // Check mutation limit
        if self.mutation_count >= MAX_OPERATIONS_PER_COMMIT {
            return Err(Error::TooManyMutations);
        }

        // Validate sizes
        if key.is_empty() {
            return Err(Error::KeyEmpty);
        }
        if key.len() > MAX_KEY_SIZE {
            return Err(Error::KeyTooLarge);
        }
        if value.len() > MAX_VALUE_SIZE {
            return Err(Error::ValueTooLarge);
        }

        // Add mutation
        self.mutations.push(Mutation::Put {
            key: key.to_vec(),
            value: value.to_vec(),
        });
        self.mutation_count += 1;

        Ok(())
    }

    pub fn delete(&mut self, key: &[u8]) -> Result<(), Error> {
        // Similar validation and addition
        // ...
    }
}
```

### Page Tracking

**Track Allocated Page**:
```rust
impl TransactionContext {
    pub fn track_allocated_page(&mut self, page_id: PageId) {
        self.allocated_pages.push(page_id);
    }

    pub fn track_modified_page(&mut self, page_id: PageId, before_image: Vec<u8>) {
        self.modified_pages.insert(page_id, before_image);
    }
}
```

### State Predicates

**State Check Methods**:
```rust
impl TransactionContext {
    pub const fn is_active(&self) -> bool {
        matches!(self.state, TransactionState::Active)
    }

    pub const fn is_preparing(&self) -> bool {
        matches!(self.state, TransactionState::Preparing)
    }

    pub const fn is_committed(&self) -> bool {
        matches!(self.state, TransactionState::Committed)
    }

    pub const fn is_aborted(&self) -> bool {
        matches!(self.state, TransactionState::Aborted)
    }
}
```

### Constants

**Size Limits**:
```rust
pub const MAX_KEY_SIZE: usize = 4096;
pub const MAX_VALUE_SIZE: usize = 16 * 1024 * 1024; // 16MB
pub const MAX_OPERATIONS_PER_COMMIT: usize = 1000;
```

### Thread Safety

**Not Send or Sync**:
```rust
// TransactionContext should NOT implement Send or Sync
// It is designed for single-threaded usage
// If multi-threading needed, wrap in Mutex<RwLock<TransactionContext>>
```

**Alternative**: If thread safety is needed:
```rust
use std::sync::{Arc, Mutex};

pub type SharedTransactionContext = Arc<Mutex<TransactionContext>>;
```

### Drop Implementation

**Resource Cleanup**:
```rust
impl Drop for TransactionContext {
    fn drop(&mut self) {
        // Resources automatically freed by Rust:
        // - mutations vector dropped
        // - allocated_pages vector dropped
        // - modified_pages HashMap dropped
        // - No explicit cleanup needed for owned data
    }
}
```

**Note**: Rust's Drop ensures all owned data is freed. Unlike Zig, no explicit allocator calls needed.

### Clone Behavior

**Not Cloneable**: TransactionContext should NOT implement Clone
- **Reason**: Would create ambiguous ownership and state duplication
- **Correctness**: Cloning transaction state leads to confusion
- **Pattern**: Each transaction is unique with exclusive ownership

### Testing Strategy

**Unit tests needed for**:
- Construction creates valid Active transaction
- put() adds mutation to mutations list
- delete() adds mutation to mutations list
- Validation rejects oversized keys/values
- Validation rejects empty keys
- Validation enforces mutation count limit
- track_allocated_page() adds page to list
- track_modified_page() stores before-image
- State transitions work correctly
- Invalid state transitions return errors
- is_active/is_preparing/etc return correct values

**Property tests for**:
- Mutation order is preserved
- Mutation count matches mutations.len()
- All mutations have same txn_id
- allocated_pages has no duplicates
- modified_pages contains all modified pages

**Integration scenarios**:
- prepare() writes to WAL and sets commit_lsn
- commit() applies mutations to database
- rollback() frees pages and restores before-images
- Transaction survives begin -> prepare -> commit
- Transaction survives begin -> rollback
- Errors during prepare don't corrupt state
- Errors during commit are handled correctly
