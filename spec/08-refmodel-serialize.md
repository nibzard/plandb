# Reference Model: Persistence Format (Serialization)

**Phase**: 8
**Task**: 8.6
**Status**: Draft
**Author**: NorthstarDB Team
**Created**: 2025-01-04

## Table of Contents
1. [Introduction](#introduction)
2. [Serialization Goals](#serialization-goals)
3. [Format Specification](#format-specification)
4. [Snapshot Serialization](#snapshot-serialization)
5. [B+Tree Serialization](#btree-serialization)
6. [History Serialization](#history-serialization)
7. [Deserialization](#deserialization)
8. [Rust Implementation Guidance](#rust-implementation-guidance)

---

## Introduction

Serialization converts the reference model's in-memory state to a persistent byte format. This enables:
- **State comparison**: Serialize both states and compare bytes
- **Cross-process validation**: Pass state between test processes
- **Debugging**: Inspect state with external tools
- **Baseline storage**: Save expected states for regression testing

The serialization format prioritizes **simplicity and clarity** over efficiency. The reference model is not a production database, so compact binary encoding or fast serialization are not requirements.

---

## Serialization Goals

### Primary Goals

#### 1. Determinism
- **Same state always produces same bytes**: Enable byte-wise comparison
- **Canonical ordering**: Keys sorted, consistent structure
- **No implementation-dependent data**: Pointers, handles omitted

#### 2. Simplicity
- **Straightforward format**: Easy to understand and implement
- **Human-readable where possible**: Use text for metadata
- **Self-describing**: Include versioning and length fields

#### 3. Completeness
- **Full state captured**: All keys, values, metadata
- **Round-trip capable**: Deserialize produces identical state
- **Version aware**: Handle format evolution

### Non-Goals

- **Compactness**: Binary size is not a concern (test data is small)
- **Speed**: Serialization performance is not critical
- **Streaming**: Entire state fits in memory for test workloads
- **Encryption**: Test data doesn't need protection

---

## Format Specification

### High-Level Structure

All serialized data follows this pattern:

```
[Header] [Payload] [Checksum]
```

#### Header
- **Magic**: 4 bytes - Format identifier (e.g., b"REFM")
- **Version**: 4 bytes (u32) - Format version number
- **Payload Type**: 4 bytes - Type identifier (snapshot, history, tree)
- **Payload Length**: 8 bytes (u64) - Size of payload in bytes

#### Payload
- Type-specific data (varies by payload type)

#### Checksum
- **CRC32**: 4 bytes - Checksum of entire serialized data (for integrity)

### Versioning

Format version follows semantic versioning:
- **Major version**: Breaking changes (incompatible)
- **Minor version**: Additive changes (backward compatible)
- **Patch version**: Bug fixes (no format change)

Current version: **1.0.0**

**Version handling**:
- Deserializer must reject unsupported major versions
- Deserializer should handle minor version upgrades (ignore unknown fields)
- Patch version changes don't affect deserialization

---

## Snapshot Serialization

### Snapshot Format

```
[Header]
[TxnId]
[ParentTxnId]
[Timestamp]
[B+Tree]
[Checksum]
```

### Field Definitions

#### TxnId
- **Type**: u64
- **Size**: 8 bytes
- **Description**: Transaction identifier
- **Encoding**: Little-endian

#### ParentTxnId
- **Type**: Option<u64>
- **Size**: 1 byte tag + 0 or 8 bytes
- **Description**: Parent transaction ID (None for txn_id 0)
- **Encoding**:
  - 0x00: None
  - 0x01: Some(u64) followed by 8-byte value

#### Timestamp
- **Type**: u64
- **Size**: 8 bytes
- **Description**: Monotonic timestamp
- **Encoding**: Little-endian

#### B+Tree
- **Type**: Serialized B+Tree (see below)
- **Size**: Variable
- **Description**: Complete tree structure

### Full Example

```
Snapshot with txn_id=5, parent=4, timestamp=100, tree has one entry ("a", "b")

Header:
  Magic: "REFM"
  Version: 0x01000000 (1.0.0)
  Type: 0x00000001 (Snapshot)
  Length: (calculated from payload)

Payload:
  TxnId: 0x0500000000000000 (5)
  ParentTxnId: 0x01 0x0400000000000000 (Some(4))
  Timestamp: 0x6400000000000000 (100)
  B+Tree: (see B+Tree serialization below)

Checksum: (CRC32 of all above)
```

---

## B+Tree Serialization

### B+Tree Format

The B+Tree is serialized in **canonical sorted form**, not in its actual node structure. This simplifies comparison and makes the format implementation-independent.

```
[Node Count]
[Entry Count]
[Entries]
```

### Field Definitions

#### Node Count
- **Type**: u32
- **Size**: 4 bytes
- **Description**: Number of nodes in tree (for validation)
- **Encoding**: Little-endian

#### Entry Count
- **Type**: u32
- **Size**: 4 bytes
- **Description**: Number of key-value pairs in tree
- **Encoding**: Little-endian

#### Entries
- **Type**: Array of serialized entries
- **Size**: Variable
- **Description**: All key-value pairs in sorted order

### Entry Format

Each entry is serialized as:

```
[Key Length] [Key Bytes] [Value Length] [Value Bytes]
```

#### Key Length
- **Type**: u32
- **Size**: 4 bytes
- **Range**: 0 to 1,000,000 (practical limit for testing)
- **Encoding**: Little-endian

#### Key Bytes
- **Type**: [u8]
- **Size**: Key Length bytes
- **Description**: Raw key bytes (no encoding/validation)

#### Value Length
- **Type**: u32
- **Size**: 4 bytes
- **Range**: 0 to 10,000,000 (practical limit for testing)
- **Encoding**: Little-endian

#### Value Bytes
- **Type**: [u8]
- **Size**: Value Length bytes
- **Description**: Raw value bytes (no encoding/validation)

### Example

Tree with entries: {("a", "1"), ("b", "2"), ("c", "3")}

```
Node Count: 0x02000000 (2 nodes: 1 internal, 1 leaf, or just 1 leaf)
Entry Count: 0x03000000 (3 entries)

Entries:
  Entry 1:
    Key Length: 0x01000000 (1)
    Key Bytes: 0x61 ("a")
    Value Length: 0x01000000 (1)
    Value Bytes: 0x31 ("1")

  Entry 2:
    Key Length: 0x01000000 (1)
    Key Bytes: 0x62 ("b")
    Value Length: 0x01000000 (1)
    Value Bytes: 0x32 ("2")

  Entry 3:
    Key Length: 0x01000000 (1)
    Key Bytes: 0x63 ("c")
    Value Length: 0x01000000 (1)
    Value Bytes: 0x33 ("3")
```

### Empty Tree

```
Node Count: 0x01000000 (1 empty leaf node)
Entry Count: 0x00000000 (0 entries)
Entries: (none)
```

### Structural Serialization (Alternative)

For debugging, optionally serialize actual node structure:

```
[Root Node]
```

Where each node is:

```
[Node Type] [Children/Entries]
```

#### Node Type
- **Type**: u8
- **Size**: 1 byte
- **Values**:
  - 0x00: Internal node
  - 0x01: Leaf node

#### Internal Node
```
[Key Count] [Keys] [Child Pointers]
```

#### Leaf Node
```
[Entry Count] [Entries]
```

**Note**: Structural serialization is useful for debugging B+Tree implementations but not required for equivalence checking.

---

## History Serialization

### History Format

Serialize entire history (all snapshots):

```
[Header]
[Snapshot Count]
[Snapshots]
[Checksum]
```

### Field Definitions

#### Snapshot Count
- **Type**: u32
- **Size**: 4 bytes
- **Description**: Number of snapshots in history
- **Encoding**: Little-endian

#### Snapshots
- **Type**: Array of serialized snapshots
- **Size**: Variable
- **Description**: All snapshots in txn_id order

Each snapshot is serialized using the Snapshot Format above.

### Example

History with 2 snapshots (txn_id 0 and 1):

```
Header:
  Magic: "REFM"
  Version: 0x01000000
  Type: 0x00000002 (History)
  Length: (calculated)

Payload:
  Snapshot Count: 0x02000000 (2)

  Snapshot 0 (txn_id=0, no parent, empty tree):
    TxnId: 0x0000000000000000
    ParentTxnId: 0x00 (None)
    Timestamp: 0x0000000000000000
    B+Tree: (empty tree)

  Snapshot 1 (txn_id=1, parent=0, tree has one entry):
    TxnId: 0x0100000000000000
    ParentTxnId: 0x01 0x0000000000000000
    Timestamp: 0x0100000000000000
    B+Tree: (tree with entry)

Checksum: (CRC32)
```

---

## Deserialization

### Deserialization Process

### deserialize_snapshot(data: &[u8]) -> Result<SnapshotState, DeserializeError>

**Purpose**: Deserialize snapshot from bytes.

**Parameters**:
- **data**: Serialized snapshot bytes

**Returns**:
- **Ok(SnapshotState)**: Deserialized snapshot
- **Err(DeserializeError)**: Error during deserialization

**Algorithm**:

1. Verify header:
   a. Check magic bytes (must be "REFM")
   b. Check version (must be supported)
   c. Check payload type (must be Snapshot)
   d. Read payload length
2. Verify checksum:
   a. Compute CRC32 of data (excluding checksum field)
   b. Compare to checksum in data
   c. If mismatch, return Err(DeserializeError::ChecksumMismatch)
3. Deserialize payload:
   a. Read TxnId (8 bytes)
   b. Read ParentTxnId (1 byte tag + optional 8 bytes)
   c. Read Timestamp (8 bytes)
   d. Deserialize B+Tree (see below)
   e. Create SnapshotState from fields
4. Return snapshot

**Error Conditions**:
- **DeserializeError::InvalidMagic**: Magic bytes incorrect
- **DeserializeError::UnsupportedVersion**: Version not supported
- **DeserializeError::InvalidType**: Payload type not Snapshot
- **DeserializeError::ChecksumMismatch**: CRC32 mismatch
- **DeserializeError::InvalidData**: Malformed data

**Complexity**:
- **Time**: O(N) to read and verify data
- **Space**: O(N) for deserialized snapshot

---

### deserialize_btree(data: &[u8]) -> Result<BTree, DeserializeError>

**Purpose**: Deserialize B+Tree from bytes (canonical sorted form).

**Parameters**:
- **data**: Serialized B+Tree bytes (payload section)

**Returns**:
- **Ok(BTree)**: Deserialized tree
- **Err(DeserializeError)**: Error during deserialization

**Algorithm**:

1. Read node count (4 bytes) - for validation only
2. Read entry count (4 bytes)
3. Allocate empty BTree
4. For i from 0 to entry_count - 1:
   a. Read key length (4 bytes)
   b. Read key bytes (key length bytes)
   c. Read value length (4 bytes)
   d. Read value bytes (value length bytes)
   e. Insert (key, value) into tree
5. Verify tree invariant: if tree.count != entry_count:
   a. Return Err(DeserializeError::CountMismatch)
6. Return tree

**Error Conditions**:
- **DeserializeError::InvalidLength**: Length field exceeds data size
- **DeserializeError::UnexpectedEof**: Data ends mid-entry
- **DeserializeError::CountMismatch**: Entry count doesn't match actual count

**Complexity**:
- **Time**: O(N * log N) where N is entry count (N insertions)
- **Space**: O(N) for deserialized tree

---

### deserialize_history(data: &[u8]) -> Result<RefModel, DeserializeError>

**Purpose**: Deserialize entire history from bytes.

**Parameters**:
- **data**: Serialized history bytes

**Returns**:
- **Ok(RefModel)**: RefModel with deserialized snapshots
- **Err(DeserializeError)**: Error during deserialization

**Algorithm**:

1. Verify header (magic, version, type, length)
2. Verify checksum
3. Read snapshot count (4 bytes)
4. Create empty RefModel
5. For i from 0 to snapshot_count - 1:
   a. Deserialize snapshot i (call deserialize_snapshot on sub-slice)
   b. Insert into model.snapshots
6. Set model.current_txn_id = snapshot_count - 1
7. Set model.current_state = last snapshot
8. Return model

**Error Conditions**:
- **DeserializeError::InvalidSnapshotCount**: Count doesn't match actual snapshots
- **DeserializeError::GapInTxnIds**: Snapshot txn_ids not sequential
- **DeserializeError::InvalidDerivation**: Snapshot doesn't derive from parent

**Complexity**:
- **Time**: O(S * N * log N) where S is snapshot count, N is avg entries per snapshot
- **Space**: O(S * N) for all snapshots

---

## Rust Implementation Guidance

### Module Structure

Serialization should be organized as:

```
ref_model/
├── serialization/
│   ├── mod.rs              # Public API
│   ├── format.rs           # Format constants and definitions
│   ├── serialize.rs        # Serialization functions
│   ├── deserialize.rs      # Deserialization functions
│   └── checksum.rs         # CRC32 implementation
└── validation/
    └── compare.rs          # Byte-wise comparison
```

### Type Definitions

#### Use Structs for Format Components

```rust
#[repr(C)]
struct Header {
    magic: [u8; 4],
    version: [u8; 4], // 4 bytes for major.minor.patch
    payload_type: [u8; 4],
    payload_length: u64,
}

const SNAPSHOT_TYPE: u32 = 1;
const HISTORY_TYPE: u32 = 2;
const BTREE_TYPE: u32 = 3;
```

**Benefits**:
- Clear format specification
- Easy to serialize/deserialize
- Type-safe (can't mix up types)

#### Use Newtypes for Serialized Data

```rust
pub struct SerializedSnapshot(Vec<u8>);
pub struct SerializedHistory(Vec<u8>);

impl SerializedSnapshot {
    pub fn as_bytes(&self) -> &[u8] {
        &self.0
    }
}
```

**Benefits**:
- Type safety (can't confuse snapshot with history bytes)
- Encapsulation (can add validation methods)
- Clear API

### Concurrency

#### Serialization is Thread-Safe (Read-Only)

```rust
fn serialize_snapshot(snapshot: &SnapshotState) -> SerializedSnapshot {
    // Only reads from snapshot
    // Safe to call concurrently
}
```

**Benefits**:
- Multiple threads can serialize same snapshot
- No locking needed
- Safe parallel serialization

### Key Decisions

#### Encoding: Binary vs JSON
**Decision**: Use binary encoding

**Reason**:
- Simpler to implement (write raw bytes)
- More compact (JSON has overhead)
- Deterministic (JSON has whitespace variations)
- Sufficient for testing (not human-readable but debuggable with tools)

#### Checksum: CRC32 vs None
**Decision**: Include CRC32 checksum

**Reason**:
- Detect corruption early
- Fast computation
- Small overhead (4 bytes)
- Useful for catching bugs in serialization code

#### B+Tree Format: Canonical vs Structural
**Decision**: Canonical sorted entry list for primary format

**Reason**:
- Implementation-independent (doesn't depend on node structure)
- Simpler to compare (just compare entry lists)
- Sufficient for equivalence checking
- Structural format can be added for debugging

### Implementation Notes

#### Step 1: Implement Format Constants
Define format specification:
- Magic bytes
- Type identifiers
- Version numbers
- Field sizes

#### Step 2: Implement Serialization
Add serialize functions:
- serialize_snapshot: Header + fields + B+Tree + checksum
- serialize_btree: Entry count + sorted entries
- serialize_history: Snapshot count + snapshots

#### Step 3: Implement Deserialization
Add deserialize functions:
- deserialize_snapshot: Read and verify, construct snapshot
- deserialize_btree: Read entries, build tree
- deserialize_history: Read snapshots, construct model

#### Step 4: Implement Checksum
Add CRC32 computation:
- Use crc crate or implement
- Compute over entire serialized data
- Verify on deserialization

### Testing Strategy

#### Unit Tests Needed For

**Serialization**:
- Empty snapshot serializes correctly
- Snapshot with data serializes deterministically
- Same state serialized twice produces identical bytes
- B+Tree entries sorted in output
- Header fields correct (magic, version, type)

**Deserialization**:
- Valid data deserializes correctly
- Invalid magic rejected
- Unsupported version rejected
- Checksum mismatch detected
- Truncated data detected

**Round-Trip**:
- Serialize then deserialize produces identical state
- Round-trip preserves all keys and values
- Round-trip preserves txn_id, parent_txn_id, timestamp

**Format Compliance**:
- Output matches format specification exactly
- All fields present and correctly sized
- Checksum computed correctly

#### Property Tests For

**Determinism**:
- Same state serialized multiple times produces identical bytes
- Different instances with same data produce identical bytes

**Round-Trip Correctness**:
- For any state, serialize-deserialize produces equivalent state
- Random states round-trip correctly

**Checksum**:
- Corrupted data detected by checksum
- Valid data passes checksum

#### Integration Scenarios

**Cross-Process Comparison**:
- Serialize state in process A
- Send bytes to process B
- Deserialize in process B
- Verify states equivalent

**Baseline Storage**:
- Serialize known good state
- Save to file
- Load and deserialize
- Compare to current state

**Regression Testing**:
- Serialize test workload result
- Compare to baseline bytes
- Fail if different

---

## Summary

Serialization provides:

- **Deterministic format**: Same state always produces same bytes
- **Complete capture**: All state information preserved
- **Round-trip capable**: Deserialize produces identical state
- **Versioned format**: Handles evolution over time
- **Integrity checking**: Checksums detect corruption

This enables **byte-wise comparison** for regression testing and **cross-process validation** for distributed testing scenarios.
