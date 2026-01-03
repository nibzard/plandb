# Mutation Types

## Purpose

Mutation types represent individual write operations within a transaction in NorthstarDB. Each mutation describes a single change to the database: either inserting/updating a key-value pair (Put) or removing a key (Delete). Mutations are buffered during a transaction, serialized to the Write-Ahead Log (WAL) for durability, and applied to the B+tree during commit. The Mutation enum provides a type-safe, memory-efficient representation of these operations.

## Types

### Mutation

**Description**: A tagged union representing a single database operation. Mutations are the fundamental unit of change in NorthstarDB, representing what a transaction intends to do to the database state.

**Variants**:
- **Put**: Insert or update a key-value pair
- **Delete**: Remove a key from the database

**Invariants**:
- Each mutation represents exactly one operation
- Mutations are immutable once created
- All mutations within a transaction share the same transaction ID
- Mutations are validated before being applied to the database

## Mutation Variants

### Put Mutation

**Description**: Represents an insertion or update operation that associates a value with a key. If the key already exists, its value is overwritten. If the key does not exist, a new entry is created.

**Fields**:
- **key**: Byte slice representing the key to insert or update
  - **Type**: Byte slice (slice of u8)
  - **Constraints**: Maximum 4KB recommended (4096 bytes)
  - **Empty Key**: Not allowed (must have at least 1 byte)
  - **Encoding**: Raw bytes, no transformation

- **value**: Byte slice representing the value to store
  - **Type**: Byte slice (slice of u8)
  - **Constraints**: Maximum 16MB recommended (16,777,216 bytes)
  - **Empty Value**: Allowed (zero-length value is valid)
  - **Encoding**: Raw bytes, no transformation

**Semantics**:
- Creates a new key-value entry if key does not exist
- Replaces existing value if key already exists
- Operation is idempotent (Put followed by another Put with same key yields final value)

**Size Limits**:
- Maximum key size: 4096 bytes (4KB)
- Maximum value size: 16,777,216 bytes (16MB)
- Total mutation size: key size + value size + encoding overhead

### Delete Mutation

**Description**: Represents a removal operation that deletes a key and its associated value from the database. If the key does not exist, the operation is a no-op but still recorded in the WAL.

**Fields**:
- **key**: Byte slice representing the key to delete
  - **Type**: Byte slice (slice of u8)
  - **Constraints**: Maximum 4KB recommended (4096 bytes)
  - **Empty Key**: Not allowed (must have at least 1 byte)
  - **Encoding**: Raw bytes, no transformation

**Semantics**:
- Removes key-value entry if key exists
- No-op if key does not exist (operation succeeds but no change)
- Operation is idempotent (Delete followed by another Delete is safe)

**Size Limits**:
- Maximum key size: 4096 bytes (4KB)
- No value field (implicitly empty)

## Encoding Format

### Binary Layout (Byte-by-Byte)

Each mutation is encoded as a variable-length record with the following structure:

```
Offset  Size  Field       Description
------  ----  -----       -----------
0       1     op_type     Operation type (0 = Put, 1 = Delete)
1       1     op_flags    Flags field (must be 0 in V0)
2       2     key_len     Key length in bytes (u16, little-endian)
4       4     val_len     Value length in bytes (u32, little-endian)
8       N     key_bytes   Key data (N = key_len)
8+N     M     val_bytes   Value data (M = val_len, only for Put)
```

### Field Descriptions

**op_type** (1 byte):
- **Value 0**: Put operation
- **Value 1**: Delete operation
- **Values 2-255**: Reserved for future operation types
- **Validation**: Only 0 and 1 are valid in V0

**op_flags** (1 byte):
- **Value 0**: No flags set (V0 default)
- **Reserved bits**: All bits reserved for future use
- **Validation**: Must be 0 in V0

**key_len** (2 bytes, u16, little-endian):
- **Purpose**: Length of key data in bytes
- **Range**: 1 to 65535 (practically limited to 4096)
- **Validation**: Must be greater than 0
- **Byte Order**: Little-endian

**val_len** (4 bytes, u32, little-endian):
- **Purpose**: Length of value data in bytes
- **Range**: 0 to 4,294,967,295 (practically limited to 16MB)
- **Put Operation**: Can be any valid size (including 0)
- **Delete Operation**: Must be 0
- **Byte Order**: Little-endian

**key_bytes** (variable length, N bytes):
- **Purpose**: Actual key data
- **Length**: Exactly key_len bytes
- **Encoding**: Raw binary data, no transformation

**val_bytes** (variable length, M bytes, Put only):
- **Purpose**: Actual value data
- **Length**: Exactly val_len bytes
- **Encoding**: Raw binary data, no transformation
- **Delete**: This field is absent (0 bytes) for Delete operations

### Encoding Examples

**Put Operation Example**:
```
Key: "user:123" (9 bytes)
Value: '{"name":"Alice"}' (17 bytes)

Encoded (35 bytes total):
Offset 0: 0x00              (op_type = Put)
Offset 1: 0x00              (op_flags = 0)
Offset 2: 0x09 0x00         (key_len = 9, little-endian)
Offset 4: 0x11 0x00 0x00 0x00 (val_len = 17, little-endian)
Offset 8: 0x75 0x73 0x65 0x72 0x3A 0x31 0x32 0x33 (key_bytes = "user:123")
Offset 17: 0x7B 0x22 0x6E 0x61 0x6D 0x65 0x22 0x3A 0x22 0x41 0x6C 0x69 0x63 0x65 0x22 0x7D (val_bytes = '{"name":"Alice"}')
```

**Delete Operation Example**:
```
Key: "user:123" (9 bytes)

Encoded (11 bytes total):
Offset 0: 0x01              (op_type = Delete)
Offset 1: 0x00              (op_flags = 0)
Offset 2: 0x09 0x00         (key_len = 9, little-endian)
Offset 4: 0x00 0x00 0x00 0x00 (val_len = 0, little-endian)
Offset 8: 0x75 0x73 0x65 0x72 0x3A 0x31 0x32 0x33 (key_bytes = "user:123")
No val_bytes field (Delete has no value)
```

### Size Calculation

**Put Operation Size**:
```
total_size = 8 (header) + key_len + val_len
```

**Delete Operation Size**:
```
total_size = 8 (header) + key_len
```

**Maximum Mutation Size**:
- Put max: 8 + 4096 + 16,777,216 = 16,781,320 bytes (approximately 16 MB)
- Delete max: 8 + 4096 = 4104 bytes (approximately 4 KB)

## Functions

### getKey(&self) -> &[u8]

**Purpose**: Extract the key from any mutation variant

**Returns**: Byte slice reference to the key

**Usage**: Common operations that need the key regardless of operation type

### calculate_serialized_size(&self) -> usize

**Purpose**: Calculate the byte size of the encoded mutation

**Returns**: Number of bytes this mutation will occupy when serialized

**Algorithm**:
1. Start with header size (8 bytes)
2. Add key_len bytes
3. If Put variant, add val_len bytes
4. If Delete variant, add 0 bytes

### serialize(&self, writer: &mut impl Write) -> Result<(), Error>

**Purpose**: Write the mutation to a byte stream

**Parameters**:
- writer: Any type implementing Write trait (file, buffer, network stream)

**Algorithm**:
1. Write op_type byte (0 for Put, 1 for Delete)
2. Write op_flags byte (must be 0)
3. Write key_len as u16 in little-endian
4. Write val_len as u32 in little-endian
5. Write key_bytes (exactly key_len bytes)
6. If Put, write val_bytes (exactly val_len bytes)
7. If Delete, skip writing val_bytes

**Error Conditions**:
- IoError: Write operation failed
- InvalidData: Mutation contains invalid data

### deserialize(reader: &mut impl Read) -> Result<Mutation, Error>

**Purpose**: Read a mutation from a byte stream

**Parameters**:
- reader: Any type implementing Read trait (file, buffer, network stream)

**Algorithm**:
1. Read op_type byte
2. Read op_flags byte, validate it equals 0
3. Read key_len as u16 (little-endian)
4. Read val_len as u32 (little-endian)
5. Read exactly key_len bytes into key_bytes
6. If op_type is Put, read exactly val_len bytes into val_bytes
7. If op_type is Delete, verify val_len equals 0
8. Construct appropriate Mutation variant
9. Validate key_len and val_len against size limits

**Error Conditions**:
- IoError: Read operation failed
- InvalidData: Corrupted encoding or size limits exceeded
- UnexpectedEof: Incomplete data

### validate(&self) -> Result<(), Error>

**Purpose**: Validate mutation against size limits and constraints

**Validation Checks**:
- Key length is within maximum (4096 bytes)
- Key length is greater than 0
- Value length is within maximum (16MB for Put)
- For Delete, value length is 0
- For Put, value bytes length matches val_len field

**Error Conditions**:
- KeyTooLarge: Key exceeds size limit
- ValueTooLarge: Value exceeds size limit
- KeyEmpty: Key has zero length
- InvalidOperation: Delete operation has non-zero value length

## Rust Enum Structure

### Enum Definition

**Basic Structure**:
```rust
pub enum Mutation {
    Put {
        key: Vec<u8>,
        value: Vec<u8>,
    },
    Delete {
        key: Vec<u8>,
    },
}
```

**Alternative with Cow** (for zero-copy where possible):
```rust
pub enum Mutation<'a> {
    Put {
        key: Cow<'a, [u8]>,
        value: Cow<'a, [u8]>,
    },
    Delete {
        key: Cow<'a, [u8]>,
    },
}
```

**Lifetime-Free Version** (for most use cases):
```rust
pub enum Mutation {
    Put {
        key: Vec<u8>,
        value: Vec<u8>,
    },
    Delete {
        key: Vec<u8>,
    },
}
```

### Type Ownership

**Owned Data (Vec<u8>)**: Recommended for most cases
- **Pros**: No lifetime parameters, easy to store in collections, simple ownership
- **Cons**: Requires allocation for each mutation
- **Use Case**: Most transaction processing and WAL writing

**Borrowed Data (&'a [u8])**: For zero-copy parsing
- **Pros**: No allocation when decoding, very efficient
- **Cons**: Lifetime parameters complicate API, limited scope
- **Use Case**: WAL decoding and validation where mutations are short-lived

**Cow (Clone on Write)**: Hybrid approach
- **Pros**: Can borrow when possible, own when necessary
- **Cons**: More complex API, runtime overhead
- **Use Case**: Advanced use cases with mixed ownership needs

### Recommended Implementation

Use owned data (Vec<u8>) for simplicity and safety:

```rust
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Mutation {
    Put {
        key: Vec<u8>,
        value: Vec<u8>,
    },
    Delete {
        key: Vec<u8>,
    },
}
```

This provides:
- Simple ownership model
- No lifetime parameters
- Easy to store in transaction context
- Compatible with serialization frameworks

## Helper Types

### Size Limits

**Description**: Constants defining maximum sizes for mutation fields

**Fields**:
- **MAX_KEY_SIZE**: Maximum key length (4096 bytes)
- **MAX_VALUE_SIZE**: Maximum value length (16,777,216 bytes)
- **MAX_OPERATIONS_PER_COMMIT**: Maximum mutations per transaction (1000)

**Purpose**: Validate mutations before encoding to prevent resource exhaustion

### EncodedOperation

**Description**: Structured representation of an encoded mutation for serialization

**Fields**:
- **op_type**: u8 (0 = Put, 1 = Delete)
- **op_flags**: u8 (must be 0)
- **key_len**: u16 (key length in bytes)
- **val_len**: u32 (value length in bytes)
- **key_bytes**: Byte slice (key data)
- **val_bytes**: Byte slice (value data, only for Put)

**Purpose**: Bridge between in-memory Mutation enum and binary encoding

## Invariants

- **Type Safety**: Each mutation is either Put or Delete, never both
- **Key Non-Empty**: All mutations have non-empty keys (at least 1 byte)
- **Delete Has No Value**: Delete mutations never have associated value data
- **Size Limits**: Keys and values respect configured maximum sizes
- **Encoding Round-Trip**: Mutation -> encode -> decode -> Mutation yields identical result
- **Order Independence**: Mutations can be applied in any order (within same transaction) for correctness validation

## Dependencies

- **Uses**: Error types module (for validation errors)
- **Used by**: Transaction context (mutation buffering), WAL (serialization), Commit processing (application to B+tree)

## Rust Implementation Guidance

### Module Structure

Define Mutation types in transaction module:
```rust
// northstar_core::txn
pub mod mutation;

pub use mutation::{Mutation, MutationError};
```

### Type Definition

**Recommended**: Use owned Vec<u8> for simplicity
```rust
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Mutation {
    Put {
        key: Vec<u8>,
        value: Vec<u8>,
    },
    Delete {
        key: Vec<u8>,
    },
}
```

**Alternative**: For zero-copy WAL decoding, use borrowed data
```rust
pub enum Mutation<'a> {
    Put {
        key: &'a [u8],
        value: &'a [u8],
    },
    Delete {
        key: &'a [u8],
    },
}
```

### Implementation Methods

**Key Extraction**:
```rust
impl Mutation {
    pub fn key(&self) -> &[u8] {
        match self {
            Mutation::Put { key, .. } => key,
            Mutation::Delete { key } => key,
        }
    }
}
```

**Size Calculation**:
```rust
impl Mutation {
    pub fn serialized_size(&self) -> usize {
        let key_len = self.key().len();
        let header_size = 8; // op_type + op_flags + key_len + val_len
        match self {
            Mutation::Put { value, .. } => header_size + key_len + value.len(),
            Mutation::Delete { .. } => header_size + key_len,
        }
    }
}
```

**Serialization**:
```rust
impl Mutation {
    pub fn serialize<W: std::io::Write>(&self, writer: &mut W) -> std::io::Result<()> {
        match self {
            Mutation::Put { key, value } => {
                writer.write_all(&[0])?; // op_type = Put
                writer.write_all(&[0])?; // op_flags = 0
                writer.write_all(&(key.len() as u16).to_le_bytes())?;
                writer.write_all(&(value.len() as u32).to_le_bytes())?;
                writer.write_all(key)?;
                writer.write_all(value)?;
            }
            Mutation::Delete { key } => {
                writer.write_all(&[1])?; // op_type = Delete
                writer.write_all(&[0])?; // op_flags = 0
                writer.write_all(&(key.len() as u16).to_le_bytes())?;
                writer.write_all(&0u32.to_le_bytes())?; // val_len = 0
                writer.write_all(key)?;
            }
        }
        Ok(())
    }
}
```

**Deserialization**:
```rust
impl Mutation {
    pub fn deserialize<R: std::io::Read>(reader: &mut R) -> Result<Self, MutationError> {
        let mut op_type = [0u8; 1];
        reader.read_exact(&mut op_type)?;

        let mut op_flags = [0u8; 1];
        reader.read_exact(&mut op_flags)?;
        if op_flags[0] != 0 {
            return Err(MutationError::InvalidFlags);
        }

        let mut key_len_bytes = [0u8; 2];
        reader.read_exact(&mut key_len_bytes)?;
        let key_len = u16::from_le_bytes(key_len_bytes) as usize;

        let mut val_len_bytes = [0u8; 4];
        reader.read_exact(&mut val_len_bytes)?;
        let val_len = u32::from_le_bytes(val_len_bytes) as usize;

        let mut key = vec![0u8; key_len];
        reader.read_exact(&mut key)?;

        match op_type[0] {
            0 => {
                // Put operation
                let mut value = vec![0u8; val_len];
                reader.read_exact(&mut value)?;
                Ok(Mutation::Put { key, value })
            }
            1 => {
                // Delete operation
                if val_len != 0 {
                    return Err(MutationError::DeleteHasValue);
                }
                Ok(Mutation::Delete { key })
            }
            _ => Err(MutationError::InvalidOpType(op_type[0])),
        }
    }
}
```

### Error Handling

**Define Mutation-Specific Errors**:
```rust
#[derive(Debug, thiserror::Error)]
pub enum MutationError {
    #[error("Key too large: {size} bytes (max {max} bytes)")]
    KeyTooLarge { size: usize, max: usize },

    #[error("Value too large: {size} bytes (max {max} bytes)")]
    ValueTooLarge { size: usize, max: usize },

    #[error("Key cannot be empty")]
    KeyEmpty,

    #[error("Invalid operation type: {0}")]
    InvalidOpType(u8),

    #[error("Invalid operation flags (must be 0)")]
    InvalidFlags,

    #[error("Delete operation cannot have value")]
    DeleteHasValue,

    #[error("IO error: {0}")]
    Io(#[from] std::io::Error),
}
```

### Validation

**Size Limits Constant**:
```rust
pub const MAX_KEY_SIZE: usize = 4096;
pub const MAX_VALUE_SIZE: usize = 16 * 1024 * 1024; // 16MB
```

**Validation Method**:
```rust
impl Mutation {
    pub fn validate(&self) -> Result<(), MutationError> {
        let key_len = self.key().len();
        if key_len == 0 {
            return Err(MutationError::KeyEmpty);
        }
        if key_len > MAX_KEY_SIZE {
            return Err(MutationError::KeyTooLarge {
                size: key_len,
                max: MAX_KEY_SIZE,
            });
        }

        match self {
            Mutation::Put { value, .. } => {
                if value.len() > MAX_VALUE_SIZE {
                    return Err(MutationError::ValueTooLarge {
                        size: value.len(),
                        max: MAX_VALUE_SIZE,
                    });
                }
            }
            Mutation::Delete { .. } => {
                // No value to validate
            }
        }

        Ok(())
    }
}
```

### Testing Strategy

**Unit tests needed for**:
- Construction of Put and Delete mutations
- Key extraction works for both variants
- Serialization produces correct byte layout
- Deserialization reconstructs original mutation
- Size calculation matches actual serialized size
- Validation rejects oversized keys/values
- Validation rejects empty keys
- Validation rejects Delete with value

**Property tests for**:
- Round-trip serialize/deserialize yields original
- Different mutations produce different encodings
- Size calculation is accurate
- Validation accepts all valid mutations
- Validation rejects all invalid mutations

**Integration tests for**:
- Mutations can be written to WAL and read back
- Multiple mutations serialize correctly in sequence
- Mutations apply correctly to B+tree
- Transaction commit processes mutations atomically