# Transaction State Machine

## Purpose

The transaction state machine manages the lifecycle of a transaction from creation through commit or abort. The state machine enforces valid state transitions, ensures operations are only allowed in appropriate states, and provides crash recovery hooks by tracking transaction progress. Each transaction progresses through a sequence of states: Active (accepting mutations), Preparing (staged for commit), Committed (durable and visible), or Aborted (discarded). The state machine prevents invalid operations, ensures atomicity, and enables deterministic recovery by encoding transaction phase in the state field.

## Overview

### State Machine Responsibilities

**Transition Enforcement**: Allow only valid state transitions
- Active → Preparing (prepare phase begins)
- Preparing → Committed (commit completes)
- Active/Preparing → Aborted (rollback anytime before commit)
- Committed/Aborted are terminal states (no transitions out)

**Operation Validation**: Allow operations only in valid states
- Mutations (put, delete) only allowed in Active state
- prepare() only allowed in Active state
- commit() only allowed in Preparing state
- abort() allowed in Active or Preparing states

**Recovery Support**: Encode transaction phase for crash recovery
- Active: No durable state, transaction never started commit
- Preparing: WAL written, transaction may be recoverable
- Committed: Fully durable, visible to other transactions
- Aborted: No durable state, transaction discarded

### State Machine Design

**Single-Threaded State**: Transaction state local to transaction
- No concurrent access to state field (single owner)
- No locks or atomic operations needed
- State changes are immediate and consistent

**Deterministic Transitions**: State progression is predictable
- Always start in Active state
- Follow linear path to terminal state
- No cycles or ambiguous transitions
- Easy to reason about and test

## TransactionState Enum

### State Variants

**Active**: Transaction is open and accepting mutations
- Description: Initial state after transaction begins
- Allowed operations: put, delete, get, scan, prepare, abort
- Transaction context: Mutation buffer growing, pages being tracked
- Durability: No durable state (transaction can be lost without affecting database)
- Recovery: Not recoverable (no WAL records written)
- Duration: From begin until prepare() or abort() called

**Preparing**: Transaction is in commit process, mutations staged
- Description: First phase of two-phase commit, WAL written
- Allowed operations: commit, abort (no mutations allowed)
- Transaction context: Mutation buffer frozen, WAL record written
- Durability: WAL record written and synced (transaction recoverable)
- Recovery: Recoverable (WAL record exists, commit not complete)
- Duration: From prepare() until commit() or abort() called

**Committed**: Transaction successfully completed
- Description: Terminal state, mutations durable and visible
- Allowed operations: None (transaction complete)
- Transaction context: Resources released, mutations applied to database
- Durability: Fully durable (WAL + B+tree + meta page all synced)
- Recovery: Fully recovered (mutations visible to all transactions)
- Duration: Forever (terminal state, no transitions out)

**Aborted**: Transaction was rolled back
- Description: Terminal state, mutations discarded
- Allowed operations: None (transaction complete)
- Transaction context: Resources released, mutations discarded
- Durability: No durable state (WAL may exist but ignored during recovery)
- Recovery: Not recovered (WAL records ignored, transaction treated as never existed)
- Duration: Forever (terminal state, no transitions out)

### State Classification

**Temporary States**: Active, Preparing
- Transactions pass through these states
- State duration is finite
- Transitions progress toward terminal state
- Operations allowed in these states

**Terminal States**: Committed, Aborted
- Transaction ends in one of these states
- No transitions out of terminal states
- No operations allowed in terminal states
- Transaction handle invalidated

## Valid State Transitions

### Transition Diagram

**Initial State**: Active (always starts here)

**Valid Transitions**:
```
Active ──────┐
  │          │
  │ prepare()│
  ▼          │
Preparing ───┼──┐
  │          │  │
  │ commit() │  │ abort()
  ▼          │  │
Committed    │  │
  │          │  │
  └──────────┴──▼
              Aborted
```

### Transition Details

**Active → Preparing** (via prepare())
- Trigger: Application calls prepare() on transaction
- Validation: Mutation count greater than 0 (transactions with no mutations are no-ops)
- Effects:
  - Mutations serialized to WAL
  - WAL record written and synced to disk
  - State changed to Preparing
  - Mutation buffer frozen (no more mutations allowed)
- Error conditions:
  - WAL write failure: Transaction remains Active, error returned
  - WAL sync failure: Transaction remains Active, error returned
  - No mutations: Transaction committed as no-op (skip to Committed)

**Preparing → Committed** (via commit())
- Trigger: Application calls commit() on transaction
- Validation: State is Preparing (WAL successfully written)
- Effects:
  - Mutations applied to B+tree
  - Modified pages written to database file
  - Meta page updated with new root page ID
  - Database file synced to disk
  - State changed to Committed
  - Resources released (mutation buffer, page tracking)
- Error conditions:
  - B+tree operation failure: Transaction remains Preparing, WAL record exists for recovery
  - Page write failure: Transaction remains Preparing, WAL record exists for recovery
  - Meta page update failure: Transaction remains Preparing, WAL record exists for recovery
  - Recovery will replay WAL record and complete commit

**Active → Aborted** (via abort())
- Trigger: Application calls abort() (rollback) on transaction
- Validation: None (abort always allowed in Active state)
- Effects:
  - Mutation buffer cleared (all mutations discarded)
  - Allocated pages freed to page free list
  - Modified pages restored from before-images
  - State changed to Aborted
  - Resources released
- Error conditions: None (abort is infallible, always succeeds)

**Preparing → Aborted** (via abort())
- Trigger: Application calls abort() (rollback) during commit
- Validation: None (abort always allowed in Preparing state)
- Effects:
  - Mutation buffer cleared
  - WAL record remains on disk (not removed)
  - Resources released
  - State changed to Aborted
- WAL Record Handling: WAL record ignored during recovery (commit not complete)
- Error conditions: None (abort is infallible, always succeeds)

### Invalid Transitions

**Preparing → Active**: Not allowed (cannot undo prepare)
- Reason: WAL record written, prepare is durable
- Error: InvalidState error if attempted
- Recovery: Must abort and begin new transaction

**Committed → Any**: Not allowed (terminal state)
- Reason: Transaction complete, mutations durable
- Error: InvalidState error if any operation attempted
- Recovery: Transaction handle invalidated, must begin new transaction

**Aborted → Any**: Not allowed (terminal state)
- Reason: Transaction complete, mutations discarded
- Error: InvalidState error if any operation attempted
- Recovery: Transaction handle invalidated, must begin new transaction

**Active → Committed**: Not allowed (must go through Preparing)
- Reason: Two-phase commit requires prepare phase
- Error: commit() returns InvalidState if called in Active state
- Recovery: Call prepare() first, then commit()

## State Validation Rules

### Operation-State Matrix

| Operation    | Active | Preparing | Committed | Aborted |
|------------- |--------|-----------|-----------|---------|
| put()        | ✓     | ✗        | ✗        | ✗       |
| delete()     | ✓     | ✗        | ✗        | ✗       |
| get()        | ✓     | ✗        | ✗        | ✗       |
| scan()       | ✓     | ✗        | ✗        | ✗       |
| prepare()    | ✓     | ✗        | ✗        | ✗       |
| commit()     | ✗     | ✓        | ✗        | ✗       |
| abort()      | ✓     | ✓        | ✗        | ✗       |
| Drop         | ✓     | ✓        | -        | -       |

Legend:
- ✓: Allowed
- ✗: Not allowed (returns InvalidState error)
- -: No-op (already in terminal state)

### Mutation Operations

**Allowed In**: Active state only

**Operations**: put, delete, get, scan

**Validation**:
```
if self.state != TransactionState::Active {
    return Err(Error::InvalidState);
}
```

**Rationale**:
- Mutations modify transaction state
- Only allowed when transaction is actively accepting changes
- Preparing: Mutation buffer frozen for commit
- Committed/Aborted: Transaction complete

**Error Handling**:
- Return InvalidState error
- Transaction state unchanged
- Application must begin new transaction

### Prepare Operation

**Allowed In**: Active state only

**Validation**:
```
if self.state != TransactionState::Active {
    return Err(Error::InvalidState);
}
```

**Preconditions**:
- Mutation count greater than 0 (unless no-op commit)
- WAL accessible and writable
- Sufficient disk space for WAL record

**State Transition**: Active → Preparing

**Effects**:
- Mutations serialized to WAL
- WAL record written and synced
- State changed to Preparing
- Mutation buffer frozen

**Error Handling**:
- WAL write failure: State remains Active, error returned
- WAL sync failure: State remains Active, error returned
- Application can retry prepare or abort

### Commit Operation

**Allowed In**: Preparing state only

**Validation**:
```
if self.state != TransactionState::Preparing {
    return Err(Error::InvalidState);
}
```

**Preconditions**:
- State is Preparing (WAL successfully written)
- B+tree accessible and writable
- Database file writable and syncable

**State Transition**: Preparing → Committed

**Effects**:
- Mutations applied to B+tree
- Modified pages written and synced
- Meta page updated and synced
- State changed to Committed
- Resources released

**Error Handling**:
- B+tree failure: State remains Preparing, WAL record exists for recovery
- Page write failure: State remains Preparing, WAL record exists for recovery
- Meta page failure: State remains Preparing, WAL record exists for recovery
- Application can abort (WAL record will be replayed during recovery)

### Abort Operation

**Allowed In**: Active or Preparing states

**Validation**:
```
if self.state == TransactionState::Committed ||
   self.state == TransactionState::Aborted {
    return Err(Error::InvalidState);
}
```

**State Transition**: Active/Preparing → Aborted

**Effects**:
- Mutation buffer cleared
- Allocated pages freed
- Modified pages restored (from before-images)
- Resources released
- State changed to Aborted

**Idempotency**: abort() can be called multiple times
- First call: Performs cleanup, transitions to Aborted
- Second call: No-op (already Aborted), returns Ok(())
- No errors from duplicate abort calls

**Infallible**: abort() always succeeds (no errors returned)
- Cleanup operations cannot fail (resources always released)
- WAL records may remain but are ignored during recovery
- Transaction guaranteed to reach Aborted state

## State Initialization

### Initial State

**Starting State**: Active (always)

**Initialization**: When transaction begins
```
pub fn begin_write() -> WriteTxn {
    WriteTxn {
        state: TransactionState::Active,
        // Other fields initialized...
    }
}
```

**Rationale**:
- All transactions start ready to accept mutations
- Active state allows all transaction operations
- Consistent starting point for all transactions

**No Other Initial States**: Transactions never start in Preparing, Committed, or Aborted
- Preparing: Requires prepare() call
- Committed: Requires successful commit
- Aborted: Requires abort() or implicit rollback

## State Termination

### Terminal States

**Committed**: Successful completion
- Mutations durable and visible
- Resources released
- Transaction handle invalidated

**Aborted**: Unsuccessful completion
- Mutations discarded
- Resources released
- Transaction handle invalidated

### Terminal State Properties

**No Transitions Out**: Once in terminal state, no state changes possible
- Committed: Cannot become Active, Preparing, or Aborted
- Aborted: Cannot become Active, Preparing, or Committed

**No Operations Allowed**: All transaction operations return InvalidState error
- put, delete, get, scan: All return InvalidState
- prepare, commit, abort: All return InvalidState

**Resource Cleanup**: All resources released before entering terminal state
- Committed: Mutation buffer applied, then dropped
- Aborted: Mutation buffer discarded, then dropped
- Page tracking, before-images, metrics: All dropped

### Handle Invalidation

**Transaction Use After Terminal State**: Operations return InvalidState error
```
let txn = db.begin_write()?;
txn.commit()?;
txn.put(b"key", b"value")?; // Error: InvalidState
```

**Compiler Enforcement**: Cannot prevent use-after-commit/abort at compile time
- Rust lifetime system cannot prevent holding reference after commit
- Runtime check required (state field validation)

**Application Best Practice**: Drop transaction handle after commit/abort
```
let txn = db.begin_write()?;
txn.commit()?;
drop(txn); // Explicit drop, prevent accidental use
// txn.put(...) would be compile error (value moved)
```

## Concurrency Considerations

### Single-Threaded State

**State Field Ownership**: Transaction owns its state exclusively
- No shared access to state field
- No locks or atomic operations needed
- State changes are immediate and consistent

**No Synchronization Required**: State not shared between threads
- WriteTxn is not Send (single-threaded)
- State accessed only by transaction owner
- No race conditions possible

**Thread Safety Guarantee**: State transitions are atomic
- Single-threaded context ensures no concurrent state changes
- State reads always see consistent value
- No torn reads or stale state

### State Visibility

**Transaction-Local State**: State not visible to other transactions
- Other transactions cannot query transaction state
- State isolation prevents dependencies on external state
- Each transaction independent

**Registry State**: Transaction registry tracks active/committed transactions
- Registry: Separate from individual transaction state
- Registry visibility: Used for conflict detection and cleanup
- Registry updates: Synchronized (internal locking)

**Recovery State**: Crash recovery uses WAL records, not transaction state
- Transaction state lost on crash (in-memory)
- WAL records provide durable transaction state
- Recovery rebuilds state from WAL

## State Machine Implementation

### State Enum Definition

**Rust Enum**:
```
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TransactionState {
    Active,
    Preparing,
    Committed,
    Aborted,
}
```

**Derive Attributes**:
- Debug: Enable debug printing
- Clone: Allow state cloning (rarely needed)
- Copy: State is small (enum discriminant), enable copy semantics
- PartialEq, Eq: Enable state comparison

### State Field in TransactionContext

**Struct Definition**:
```
pub struct TransactionContext {
    pub state: TransactionState,
    // Other fields...
}
```

**Initialization**:
```
impl TransactionContext {
    pub fn new(txn_id: TransactionId) -> Self {
        Self {
            state: TransactionState::Active,
            // Other field initialization...
        }
    }
}
```

### State Validation Functions

**Check Active State**:
```
impl TransactionContext {
    pub fn require_active(&self) -> Result<(), Error> {
        if self.state != TransactionState::Active {
            return Err(Error::InvalidState);
        }
        Ok(())
    }
}
```

**Check Preparing State**:
```
impl TransactionContext {
    pub fn require_preparing(&self) -> Result<(), Error> {
        if self.state != TransactionState::Preparing {
            return Err(Error::InvalidState);
        }
        Ok(())
    }
}
```

**Check Non-Terminal State**:
```
impl TransactionContext {
    pub fn require_mutable(&self) -> Result<(), Error> {
        match self.state {
            TransactionState::Committed | TransactionState::Aborted => {
                return Err(Error::InvalidState);
            }
            TransactionState::Active | TransactionState::Preparing => Ok(()),
        }
    }
}
```

### State Transition Functions

**Transition to Preparing**:
```
impl TransactionContext {
    pub fn transition_to_preparing(&mut self) -> Result<(), Error> {
        if self.state != TransactionState::Active {
            return Err(Error::InvalidState);
        }
        self.state = TransactionState::Preparing;
        Ok(())
    }
}
```

**Transition to Committed**:
```
impl TransactionContext {
    pub fn transition_to_committed(&mut self) -> Result<(), Error> {
        if self.state != TransactionState::Preparing {
            return Err(Error::InvalidState);
        }
        self.state = TransactionState::Committed;
        Ok(())
    }
}
```

**Transition to Aborted**:
```
impl TransactionContext {
    pub fn transition_to_aborted(&mut self) -> Result<(), Error> {
        match self.state {
            TransactionState::Committed | TransactionState::Aborted => {
                return Err(Error::InvalidState);
            }
            TransactionState::Active | TransactionState::Preparing => {
                self.state = TransactionState::Aborted;
                Ok(())
            }
        }
    }
}
```

### State Predicates

**Convenience Functions**:
```
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

    pub const fn is_terminal(&self) -> bool {
        matches!(self.state, TransactionState::Committed | TransactionState::Aborted)
    }

    pub const fn is_mutable(&self) -> bool {
        matches!(self.state, TransactionState::Active | TransactionState::Preparing)
    }
}
```

## Error Handling

### InvalidState Error

**Definition**: Operation attempted in invalid state

**Error Type**:
```
#[derive(Debug, thiserror::Error)]
#[error("Invalid transaction state: {state:?}, required: {required:?}")]
pub struct InvalidStateError {
    pub state: TransactionState,
    pub required: TransactionState,
}
```

**When Returned**:
- put, delete, get, scan called in non-Active state
- prepare called in non-Active state
- commit called in non-Preparing state
- abort called in terminal state (Committed or Aborted)

**Recovery**: Application must begin new transaction
- Transaction handle invalidated
- No recovery possible from terminal state
- Application should drop transaction handle and begin new transaction

### State Machine Invariants

**Invariant 1**: State always valid enum value
- Rust enum ensures state is one of defined variants
- No undefined or invalid states possible

**Invariant 2**: Transitions only follow valid paths
- State transition functions validate before changing state
- Invalid transitions return errors, state unchanged

**Invariant 3**: Terminal states never transition
- Once Committed or Aborted, state never changes
- Operations on terminal states return errors

**Invariant 4**: Active state allows all mutation operations
- If state is Active, put, delete, get, scan all allowed
- No additional checks needed beyond state validation

## Testing Requirements

### Unit Tests

**State Initialization Tests**:
- New transaction starts in Active state
- State field correctly initialized
- State predicates return correct values (is_active, etc.)

**Valid Transition Tests**:
- Active → Preparing via prepare(): Succeeds
- Preparing → Committed via commit(): Succeeds
- Active → Aborted via abort(): Succeeds
- Preparing → Aborted via abort(): Succeeds

**Invalid Transition Tests**:
- Preparing → Active: Returns InvalidState error
- Committed → Any: Returns InvalidState error
- Aborted → Any: Returns InvalidState error
- Active → Committed (skipping Preparing): Returns InvalidState error

**Operation Validation Tests**:
- put in Active state: Succeeds
- put in Preparing state: Returns InvalidState error
- put in Committed state: Returns InvalidState error
- commit in Active state: Returns InvalidState error
- commit in Preparing state: Succeeds
- prepare in Preparing state: Returns InvalidState error
- abort in Active state: Succeeds
- abort in Preparing state: Succeeds
- abort in Committed state: Returns InvalidState error

**Idempotency Tests**:
- abort called twice in Active state: Both succeed, state Aborted after first
- abort called twice in Preparing state: Both succeed, state Aborted after first

**State Predicate Tests**:
- is_active returns true only in Active state
- is_preparing returns true only in Preparing state
- is_committed returns true only in Committed state
- is_aborted returns true only in Aborted state
- is_terminal returns true for Committed and Aborted
- is_mutable returns true for Active and Preparing

### Integration Tests

**Commit Workflow Tests**:
- begin (Active) → prepare (Preparing) → commit (Committed): All transitions succeed
- begin (Active) → abort (Aborted): Rollback succeeds
- begin (Active) → prepare (Preparing) → abort (Aborted): Rollback during commit succeeds

**Error Recovery Tests**:
- prepare fails (WAL error): State remains Active, can retry or abort
- commit fails (B+tree error): State remains Preparing, can abort
- abort after prepare failure: Succeeds, state Aborted

**Terminal State Tests**:
- Operations after commit: All return InvalidState error
- Operations after abort: All return InvalidState error
- Transaction handle invalidated: Cannot perform further operations

### Property Tests

**State Machine Properties**:
- State always one of defined variants (enum invariant)
- State transitions only follow valid paths (no invalid transitions)
- Terminal states never transition out (no transitions from Committed/Aborted)
- Active state always allows mutations (operation validation)

**Determinism Properties**:
- Same operations always produce same state progression
- State transitions are deterministic (no randomness)
- No cycles in state graph (always progresses toward terminal state)

**Idempotency Properties**:
- abort can be called multiple times safely
- State after first abort equals state after subsequent aborts
- No state changes after terminal state reached

### Hardening Tests

**Stress Tests**:
- Rapid state transitions: System stable
- Many transactions in various states: No resource leaks
- Concurrent state changes: Not applicable (single-threaded)

**Crash Recovery Tests**:
- Crash in Active state: No WAL record, transaction not recovered
- Crash in Preparing state: WAL record exists, transaction recovered during WAL replay
- Crash in Committed state: Transaction fully durable, already visible
- Crash in Aborted state: No WAL record or WAL record ignored

## Rust Implementation Guidance

### Type Definition

**TransactionState Enum**:
```
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TransactionState {
    Active,
    Preparing,
    Committed,
    Aborted,
}
```

### State Field in TransactionContext

**Struct Definition**:
```
pub struct TransactionContext {
    pub state: TransactionState,
    pub txn_id: TransactionId,
    pub mutations: Vec<Mutation>,
    // Other fields...
}

impl TransactionContext {
    pub fn new(txn_id: TransactionId) -> Self {
        Self {
            state: TransactionState::Active,
            txn_id,
            mutations: Vec::new(),
            // Other initialization...
        }
    }
}
```

### State Validation in Operations

**put Operation**:
```
impl TransactionContext {
    pub fn put(&mut self, key: &[u8], value: &[u8]) -> Result<(), Error> {
        if self.state != TransactionState::Active {
            return Err(Error::InvalidState {
                state: self.state,
                required: TransactionState::Active,
            });
        }

        // Perform put operation...
        Ok(())
    }
}
```

**prepare Operation**:
```
impl TransactionContext {
    pub fn prepare(&mut self, wal: &mut Wal) -> Result<(), Error> {
        if self.state != TransactionState::Active {
            return Err(Error::InvalidState {
                state: self.state,
                required: TransactionState::Active,
            });
        }

        // Perform prepare operation (write WAL, etc.)
        // ...

        self.state = TransactionState::Preparing;
        Ok(())
    }
}
```

**commit Operation**:
```
impl TransactionContext {
    pub fn commit(&mut self, pager: &mut Pager) -> Result<(), Error> {
        if self.state != TransactionState::Preparing {
            return Err(Error::InvalidState {
                state: self.state,
                required: TransactionState::Preparing,
            });
        }

        // Perform commit operation (apply mutations, etc.)
        // ...

        self.state = TransactionState::Committed;
        Ok(())
    }
}
```

**abort Operation**:
```
impl TransactionContext {
    pub fn abort(&mut self, pager: &mut Pager) {
        match self.state {
            TransactionState::Committed | TransactionState::Aborted => {
                // Already in terminal state, no-op
                return;
            }
            TransactionState::Active | TransactionState::Preparing => {
                // Perform cleanup (clear mutations, free pages, etc.)
                // ...

                self.state = TransactionState::Aborted;
            }
        }
    }
}
```

### Error Type Definition

**InvalidState Error**:
```
#[derive(Debug, thiserror::Error)]
#[error("Invalid transaction state: {state:?}, required: {required:?}")]
pub struct InvalidStateError {
    pub state: TransactionState,
    pub required: TransactionState,
}

// Or as a variant in a larger Error enum:
#[derive(Debug, thiserror::Error)]
pub enum Error {
    #[error("Invalid transaction state: {state:?}, required: {required:?}")]
    InvalidState { state: TransactionState, required: TransactionState },

    // Other error variants...
}
```

### Testing Implementation

**State Transition Test**:
```
#[test]
fn test_state_transitions() {
    let mut ctx = TransactionContext::new(TransactionId::new(1));

    // Initial state
    assert_eq!(ctx.state, TransactionState::Active);
    assert!(ctx.is_active());

    // Active → Preparing
    ctx.prepare(&mut wal).unwrap();
    assert_eq!(ctx.state, TransactionState::Preparing);
    assert!(ctx.is_preparing());

    // Preparing → Committed
    ctx.commit(&mut pager).unwrap();
    assert_eq!(ctx.state, TransactionState::Committed);
    assert!(ctx.is_committed());
    assert!(ctx.is_terminal());
}
```

**Invalid Transition Test**:
```
#[test]
fn test_invalid_transitions() {
    let mut ctx = TransactionContext::new(TransactionId::new(1));

    // Try to commit without preparing
    let result = ctx.commit(&mut pager);
    assert!(matches!(result, Err(Error::InvalidState { .. })));

    // State unchanged
    assert_eq!(ctx.state, TransactionState::Active);
}
```

**Operation Validation Test**:
```
#[test]
fn test_operation_validation() {
    let mut ctx = TransactionContext::new(TransactionId::new(1));

    // put in Active state: succeeds
    ctx.put(b"key", b"value").unwrap();

    // Transition to Preparing
    ctx.prepare(&mut wal).unwrap();

    // put in Preparing state: fails
    let result = ctx.put(b"key2", b"value2");
    assert!(matches!(result, Err(Error::InvalidState { .. })));
}
```

## Dependencies

- **Uses**:
  - TransactionState type (state enum)
  - TransactionContext type (state field)
  - Error types (InvalidState error)

- **Used By**:
  - All transaction operations (put, delete, get, scan, prepare, commit, abort)
  - Transaction begin (initializes state to Active)
  - Drop trait (implicit rollback from non-terminal states)

## Related Specifications

- **Transaction Overview**: rust/04-txn-overview.md - Transaction lifecycle and state machine
- **TransactionContext**: rust/04-txn-context.md - State field and transaction structure
- **Transaction Commit**: rust/04-txn-commit.md - State transitions during commit
- **Transaction Rollback**: rust/04-txn-rollback.md - State transitions during abort
- **Semantics**: spec/semantics_v0.md - ACID guarantees and transaction isolation
