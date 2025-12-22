# Correctness Contracts V0

This document defines formal correctness contracts for NorthstarDB V0. Each contract is written as a verifiable property that can be tested automatically.

## Contract Format

Each contract follows this format:
- **Contract ID**: Unique identifier
- **Property**: Formal statement of the contract
- **Preconditions**: Required state before testing
- **Postconditions**: Required state after testing
- **Test Method**: How to verify the contract
- **Error Conditions**: Expected failure modes

---

## Atomicity Contracts

### AC-001: Commit Atomicity
**Property**: A successful commit makes all transaction changes visible atomically; a failed commit makes none visible.

**Preconditions**:
- Database is open with valid state
- Write transaction is begun
- N operations (put/del) are executed in the transaction

**Postconditions** (after successful commit):
- All N operations are visible to `begin_read(latest)`
- All operations are visible to time-travel queries at the new TxnId
- No partial state is visible

**Postconditions** (after failed commit/abort):
- None of the N operations are visible to any read transaction
- Database state is unchanged from before transaction began

**Test Method**:
1. Begin write transaction
2. Execute N operations
3. Commit or abort
4. Verify visibility through `begin_read(latest)` and enumeration
5. Verify time-travel queries at new TxnId (if committed)

**Error Conditions**: Database corruption should trigger explicit error, not silent corruption

---

### AC-002: Concurrent Read Visibility
**Property**: Readers never see partial effects of an in-flight write transaction.

**Preconditions**:
- Multiple read transactions are active
- A write transaction begins and executes operations

**Postconditions**:
- All existing read transactions see pre-transaction state only
- New read transactions (before commit) see pre-transaction state only
- No reader sees any intermediate state

**Test Method**:
1. Start M read transactions with `begin_read(latest)`
2. Begin write transaction
3. Execute N operations
4. Verify all M readers still see original state
5. Begin new read transaction, verify it sees original state
6. Commit write transaction
7. Verify new read transactions see committed state

**Error Conditions**: Any reader seeing in-flight state is a contract violation

---

## Snapshot Isolation Contracts

### SI-001: Snapshot Immutability
**Property**: A read transaction's view never changes after creation.

**Preconditions**:
- Read transaction created at TxnId T
- Concurrent write transactions may commit

**Postconditions**:
- All reads in the transaction return the same values as if executed at time T
- Range scans return the same set of keys throughout the transaction
- No committed writes after T are visible

**Test Method**:
1. Begin read transaction at TxnId T
2. Record initial state of multiple keys
3. Execute concurrent write transactions that modify those keys
4. Re-read same keys in original transaction
5. Verify values are unchanged from step 2
6. Repeat range scans, verify same key set

**Error Conditions**: Any change in observed values violates the contract

---

### SI-002: Time Travel Accuracy
**Property**: `begin_read(txn_id)` returns exactly the database state at that transaction.

**Preconditions**:
- Database has committed transactions with IDs T1 < T2 < T3
- Each transaction made distinct changes

**Postconditions**:
- `begin_read(T1)` sees only changes from ≤ T1
- `begin_read(T2)` sees changes from ≤ T2, not T3
- `begin_read(T3)` sees all changes

**Test Method**:
1. Create known state with sequential transactions
2. Record exact changes made in each transaction
3. Open snapshots at each TxnId
4. Verify each snapshot contains exactly the changes up to that point
5. Cross-verify against reference model

**Error Conditions**: Snapshot containing wrong changes violates contract

---

## Durability Contracts

### DU-001: Crash Recovery Durability
**Property**: After `commit()` returns success, the committed state survives process crash and restart.

**Preconditions**:
- Database is open and functional
- Write transaction commits successfully

**Postconditions** (after crash and restart):
- Database reopens successfully
- Committed transaction is visible
- Database state matches post-commit state exactly

**Test Method**:
1. Begin write transaction
2. Execute operations
3. Commit successfully
4. Kill process abruptly (kill -9)
5. Restart and reopen database
6. Verify committed changes are present
7. Verify database state via enumeration

**Error Conditions**: Missing committed state after restart violates contract

---

### DU-002: Fsync Ordering Guarantee
**Property**: Commit success implies all required fsync operations completed in correct order.

**Preconditions**:
- Write transaction with N operations
- Storage system honors fsync semantics

**Postconditions**:
- Data pages are durably stored
- Commit record is durably stored
- Meta page pointing to new root is durably stored
- All writes are fsynced before commit returns

**Test Method**:
1. Enable detailed fsync tracking
2. Execute commit with operations
3. Verify fsync sequence: data → commit record → meta
4. Crash after commit returns
5. Verify recovery finds consistent state

**Error Conditions**: Incorrect fsync ordering or missing fsyncs violates contract

---

## Commit Stream Contracts

### CS-001: Canonical Commit Records
**Property**: Every successful commit produces a canonical, deterministic commit record.

**Preconditions**:
- Write transaction with N operations
- Transaction commits successfully

**Postconditions**:
- Exactly one commit record is produced
- Record contains all N operations in correct order
- Record format matches specification exactly
- Record can reproduce the transaction effects when replayed

**Test Method**:
1. Execute transaction with known operations
2. Extract generated commit record
3. Verify format matches `spec/commit_record_v0.md`
4. Replay record into empty database
5. Verify resulting state matches committed state

**Error Conditions**: Missing, malformed, or non-deterministic records violate contract

---

### CS-002: Deterministic Replay
**Property**: Replaying commit records in order produces exactly the same database state.

**Preconditions**:
- Sequence of committed transactions T1, T2, ..., Tn
- All commit records are available

**Postconditions**:
- Replay of records in order produces state identical to original
- Each intermediate replay state matches corresponding snapshot
- Final database state is byte-identical

**Test Method**:
1. Execute sequence of transactions
2. Record database state after each transaction
3. Extract all commit records
4. Replay into empty database
5. Compare state after each replayed transaction
6. Verify final states are identical

**Error Conditions**: Any divergence between original and replayed state violates contract

---

## Meta Page Contracts

### MP-001: Atomic Meta Toggle
**Property**: Meta page updates are atomic; recovery finds exactly one valid meta.

**Preconditions**:
- Database has valid meta pages A and B
- New transaction commits

**Postconditions**:
- Exactly one meta page points to the new root
- The other meta page points to the old root
- Both pages have valid checksums
- Recovery selects the meta with higher TxnId

**Test Method**:
1. Record current meta page states
2. Commit transaction
3. Verify exactly one meta page updated
4. Verify both checksums are valid
5. Test recovery selects correct meta
6. Test torn write detection

**Error Conditions**: Both pages pointing to new root or ambiguous recovery violates contract

---

## Reference Model Integration

### RM-001: Byte-Identical Equivalence
**Property**: Database state is byte-identical to a reference model implementation.

**Preconditions**:
- Same sequence of operations applied to both database and reference model
- Reference model implements correct MVCC semantics

**Postconditions**:
- All keys and values are identical
- All transaction boundaries are identical
- All snapshot contents are identical

**Test Method**:
1. Initialize both database and reference model
2. Apply random sequence of operations
3. Compare final states byte-by-byte
4. Compare snapshot contents at various TxnIds
5. Verify time-travel queries match

**Error Conditions**: Any divergence from reference model violates contract

---

## Contract Violation Handling

### Required Behavior

All contract violations must:
1. Return explicit, descriptive error codes
2. Never cause undefined behavior or silent corruption
3. Leave database in a consistent state
4. Be detectable through automated testing

### Acceptable Error Modes

- **Immediate Detection**: Contract violation detected during operation
- **Recovery Detection**: Violation detected during crash recovery
- **Validation Detection**: Violation detected by integrity checks

### Unacceptable Behaviors

- Silent data corruption
- Undefined behavior or crashes
- Inconsistent or ambiguous states
- Loss of committed data

---

## Testing Framework Integration

These contracts are designed to be verified by:
1. **Unit Tests**: Individual contract verification
2. **Property Tests**: Randomized testing against reference models
3. **Hardening Tests**: Crash and corruption injection
4. **Benchmark Integration**: Performance under contract compliance

Each contract should have corresponding test implementations that:
- Test both success and failure paths
- Include edge cases and boundary conditions
- Provide clear pass/fail criteria
- Generate actionable failure diagnostics