//! WAL commit record structures
//!
//! Types for encoding and decoding transaction commit records in the WAL.

use crate::checksum;
use crate::error::{Error, Result, ValidationError};
use byteorder::{ByteOrder, LittleEndian};
use std::fmt;

/// Maximum key size for operations (4KB)
pub const MAX_KEY_SIZE: u32 = 4 * 1024;

/// Maximum value size for operations (16MB)
pub const MAX_VALUE_SIZE: u32 = 16 * 1024 * 1024;

/// Maximum number of operations per commit
pub const MAX_OPERATIONS_PER_COMMIT: u32 = 10000;

/// Magic number for commit payload header ("CMIT")
pub const COMMIT_MAGIC: u32 = 0x434D4954;

/// Size of commit payload header in bytes
pub const COMMIT_HEADER_SIZE: usize = 32;

/// Operation type enum
#[repr(u8)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum OperationType {
    /// Put operation - insert or update a key-value pair
    Put = 0,
    /// Delete operation - remove a key
    Delete = 1,
}

impl OperationType {
    /// Convert from u8
    pub fn from_u8(val: u8) -> Option<Self> {
        match val {
            0 => Some(OperationType::Put),
            1 => Some(OperationType::Delete),
            _ => None,
        }
    }

    /// Convert to u8
    pub fn to_u8(self) -> u8 {
        self as u8
    }
}

/// Commit payload header
///
/// Header specific to commit record payloads. Contains metadata about
/// the transaction being committed.
#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct CommitPayloadHeader {
    /// Magic number ("CMIT")
    pub commit_magic: u32,
    /// Transaction ID (repeated from outer header)
    pub txn_id: u64,
    /// New B+tree root page after commit (0 if no change)
    pub root_page_id: u64,
    /// Padding bytes (must be 0)
    pub padding: u32,
    /// Number of encoded operations that follow
    pub op_count: u32,
    /// Reserved field (must be 0 in V0)
    pub reserved: u32,
}

impl Default for CommitPayloadHeader {
    fn default() -> Self {
        CommitPayloadHeader {
            commit_magic: COMMIT_MAGIC,
            txn_id: 0,
            root_page_id: 0,
            padding: 0,
            op_count: 0,
            reserved: 0,
        }
    }
}

impl CommitPayloadHeader {
    /// Create a new commit payload header
    pub fn new(txn_id: u64, root_page_id: u64, op_count: u32) -> Self {
        CommitPayloadHeader {
            commit_magic: COMMIT_MAGIC,
            txn_id,
            root_page_id,
            padding: 0,
            op_count,
            reserved: 0,
        }
    }

    /// Serialize header to bytes
    pub fn to_bytes(&self) -> [u8; COMMIT_HEADER_SIZE] {
        let mut buf = [0u8; COMMIT_HEADER_SIZE];

        LittleEndian::write_u32(&mut buf[0..4], self.commit_magic);
        LittleEndian::write_u64(&mut buf[4..12], self.txn_id);
        LittleEndian::write_u64(&mut buf[12..20], self.root_page_id);
        LittleEndian::write_u32(&mut buf[20..24], self.padding);
        LittleEndian::write_u32(&mut buf[24..28], self.op_count);
        LittleEndian::write_u32(&mut buf[28..32], self.reserved);

        buf
    }

    /// Deserialize header from bytes
    pub fn from_bytes(data: &[u8]) -> Result<Self> {
        if data.len() < COMMIT_HEADER_SIZE {
            return Err(Error::Validation(ValidationError::InvalidHeaderSize {
                expected: COMMIT_HEADER_SIZE,
                actual: data.len(),
            }));
        }

        let header = CommitPayloadHeader {
            commit_magic: LittleEndian::read_u32(&data[0..4]),
            txn_id: LittleEndian::read_u64(&data[4..12]),
            root_page_id: LittleEndian::read_u64(&data[12..20]),
            padding: LittleEndian::read_u32(&data[20..24]),
            op_count: LittleEndian::read_u32(&data[24..28]),
            reserved: LittleEndian::read_u32(&data[28..32]),
        };

        Ok(header)
    }

    /// Validate commit payload header
    pub fn validate(&self) -> Result<()> {
        // Check magic number
        if self.commit_magic != COMMIT_MAGIC {
            return Err(Error::Validation(ValidationError::InvalidCommitMagic {
                expected: COMMIT_MAGIC,
                actual: self.commit_magic,
            }));
        }

        // Check reserved field
        if self.reserved != 0 {
            return Err(Error::Validation(ValidationError::InvalidReservedField {
                value: self.reserved,
            }));
        }

        // Check operation count
        if self.op_count > MAX_OPERATIONS_PER_COMMIT {
            return Err(Error::Validation(ValidationError::TooManyOperations {
                count: self.op_count,
                max: MAX_OPERATIONS_PER_COMMIT,
            }));
        }

        Ok(())
    }

    /// Calculate total payload size including header and operations
    pub fn calculate_payload_size(&self, operations: &[EncodedOperation]) -> usize {
        let ops_size: usize = operations.iter().map(|op| op.size()).sum();
        COMMIT_HEADER_SIZE + ops_size
    }
}

/// Encoded operation
///
/// A single operation (Put or Delete) within a commit record in serialized form.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct EncodedOperation {
    /// Operation type
    pub op_type: OperationType,
    /// Operation flags (must be 0 in V0)
    pub op_flags: u8,
    /// Length of key in bytes
    pub key_len: u16,
    /// Length of value in bytes (must be 0 for Delete)
    pub val_len: u32,
    /// The key data
    pub key_bytes: Vec<u8>,
    /// The value data (only present for Put)
    pub val_bytes: Option<Vec<u8>>,
}

impl EncodedOperation {
    /// Create a new Put operation
    pub fn new_put(key: Vec<u8>, value: Vec<u8>) -> Result<Self> {
        let key_len = key.len() as u16;
        let val_len = value.len() as u32;

        // Validate sizes
        if key_len as u32 > MAX_KEY_SIZE {
            return Err(Error::SizeLimit(crate::error::SizeLimitError::KeyTooLarge {
                size: key_len as usize,
                max: MAX_KEY_SIZE as usize,
            }));
        }

        if val_len > MAX_VALUE_SIZE {
            return Err(Error::SizeLimit(crate::error::SizeLimitError::ValueTooLarge {
                size: val_len as usize,
                max: MAX_VALUE_SIZE as usize,
            }));
        }

        Ok(EncodedOperation {
            op_type: OperationType::Put,
            op_flags: 0,
            key_len,
            val_len,
            key_bytes: key,
            val_bytes: Some(value),
        })
    }

    /// Create a new Delete operation
    pub fn new_delete(key: Vec<u8>) -> Result<Self> {
        let key_len = key.len() as u16;

        // Validate size
        if key_len as u32 > MAX_KEY_SIZE {
            return Err(Error::SizeLimit(crate::error::SizeLimitError::KeyTooLarge {
                size: key_len as usize,
                max: MAX_KEY_SIZE as usize,
            }));
        }

        Ok(EncodedOperation {
            op_type: OperationType::Delete,
            op_flags: 0,
            key_len,
            val_len: 0,
            key_bytes: key,
            val_bytes: None,
        })
    }

    /// Calculate the serialized size of this operation
    pub fn size(&self) -> usize {
        // Fixed part: op_type (1) + op_flags (1) + key_len (2) + val_len (4) = 8 bytes
        let fixed_size = 8;
        let key_size = self.key_bytes.len();
        let val_size = self.val_bytes.as_ref().map(|v| v.len()).unwrap_or(0);

        fixed_size + key_size + val_size
    }

    /// Serialize operation to bytes
    pub fn to_bytes(&self) -> Vec<u8> {
        let mut buf = Vec::with_capacity(self.size());

        buf.push(self.op_type.to_u8());
        buf.push(self.op_flags);

        // Extend buffer for key_len and val_len
        let mut key_len_buf = [0u8; 2];
        LittleEndian::write_u16(&mut key_len_buf, self.key_len);
        buf.extend_from_slice(&key_len_buf);

        let mut val_len_buf = [0u8; 4];
        LittleEndian::write_u32(&mut val_len_buf, self.val_len);
        buf.extend_from_slice(&val_len_buf);

        // Add key and value bytes
        buf.extend_from_slice(&self.key_bytes);
        if let Some(ref val) = self.val_bytes {
            buf.extend_from_slice(val);
        }

        buf
    }

    /// Deserialize operation from bytes
    pub fn from_bytes(data: &[u8]) -> Result<Self> {
        // Minimum size is 8 bytes (fixed header)
        if data.len() < 8 {
            return Err(Error::Validation(ValidationError::Generic(
                "Operation data too short".to_string(),
            )));
        }

        let op_type = OperationType::from_u8(data[0])
            .ok_or_else(|| Error::Validation(ValidationError::InvalidOperationType { type_val: data[0] }))?;

        let op_flags = data[1];
        let key_len = LittleEndian::read_u16(&data[2..4]) as usize;
        let val_len = LittleEndian::read_u32(&data[4..8]) as usize;

        // Check flags
        if op_flags != 0 {
            return Err(Error::Validation(ValidationError::InvalidOperationFlags {
                flags: op_flags,
            }));
        }

        // Check total data length
        let total_required = 8 + key_len + val_len;
        if data.len() < total_required {
            return Err(Error::Validation(ValidationError::Generic(
                "Operation data truncated".to_string(),
            )));
        }

        let key_bytes = data[8..8 + key_len].to_vec();
        let val_bytes = if val_len > 0 {
            Some(data[8 + key_len..8 + key_len + val_len].to_vec())
        } else {
            None
        };

        let op = EncodedOperation {
            op_type,
            op_flags,
            key_len: key_len as u16,
            val_len: val_len as u32,
            key_bytes,
            val_bytes,
        };

        // Validate the operation
        op.validate()?;

        Ok(op)
    }

    /// Validate operation fields
    pub fn validate(&self) -> Result<()> {
        // Check flags
        if self.op_flags != 0 {
            return Err(Error::Validation(ValidationError::InvalidOperationFlags {
                flags: self.op_flags,
            }));
        }

        // Check key length matches
        if self.key_bytes.len() != self.key_len as usize {
            return Err(Error::Validation(ValidationError::KeyLengthMismatch {
                expected: self.key_len as u16,
                actual: self.key_bytes.len(),
            }));
        }

        // Check value length matches for Put
        if self.op_type == OperationType::Put {
            if let Some(ref val) = self.val_bytes {
                if val.len() != self.val_len as usize {
                    return Err(Error::Validation(ValidationError::ValueLengthMismatch {
                        expected: self.val_len as u32,
                        actual: val.len(),
                    }));
                }
            } else {
                return Err(Error::Validation(ValidationError::Generic(
                    "Put operation missing value".to_string(),
                )));
            }
        }

        // Check Delete has no value
        if self.op_type == OperationType::Delete {
            if self.val_len != 0 || self.val_bytes.is_some() {
                return Err(Error::Validation(ValidationError::DeleteHasValue));
            }
        }

        Ok(())
    }

    /// Get operation type
    pub fn operation_type(&self) -> OperationType {
        self.op_type
    }

    /// Get key bytes
    pub fn key(&self) -> &[u8] {
        &self.key_bytes
    }

    /// Get value bytes (only for Put operations)
    pub fn value(&self) -> Option<&[u8]> {
        self.val_bytes.as_deref()
    }
}

/// Mutation enum - in-memory representation before encoding
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Mutation {
    /// Put mutation - insert or update a key-value pair
    Put { key: Vec<u8>, value: Vec<u8> },
    /// Delete mutation - remove a key
    Delete { key: Vec<u8> },
}

impl Mutation {
    /// Get the key for this mutation
    pub fn key(&self) -> &[u8] {
        match self {
            Mutation::Put { key, .. } => key,
            Mutation::Delete { key } => key,
        }
    }

    /// Get the value for this mutation (only for Put)
    pub fn value(&self) -> Option<&[u8]> {
        match self {
            Mutation::Put { value, .. } => Some(value),
            Mutation::Delete { .. } => None,
        }
    }

    /// Check if this is a Put mutation
    pub fn is_put(&self) -> bool {
        matches!(self, Mutation::Put { .. })
    }

    /// Check if this is a Delete mutation
    pub fn is_delete(&self) -> bool {
        matches!(self, Mutation::Delete { .. })
    }

    /// Convert to EncodedOperation
    pub fn encode(&self) -> Result<EncodedOperation> {
        match self {
            Mutation::Put { key, value } => {
                EncodedOperation::new_put(key.clone(), value.clone())
            }
            Mutation::Delete { key } => {
                EncodedOperation::new_delete(key.clone())
            }
        }
    }
}

impl TryFrom<EncodedOperation> for Mutation {
    type Error = Error;

    fn try_from(op: EncodedOperation) -> Result<Self> {
        match op.op_type {
            OperationType::Put => {
                let value = op.val_bytes.ok_or_else(|| {
                    Error::Validation(ValidationError::Generic(
                        "Put operation missing value".to_string(),
                    ))
                })?;
                Ok(Mutation::Put {
                    key: op.key_bytes,
                    value,
                })
            }
            OperationType::Delete => Ok(Mutation::Delete {
                key: op.key_bytes,
            }),
        }
    }
}

/// Commit record - high-level in-memory representation
#[derive(Debug, Clone)]
pub struct CommitRecord {
    /// Unique transaction identifier
    pub txn_id: u64,
    /// B+tree root page after applying mutations
    pub root_page_id: u64,
    /// Array of mutations in this transaction
    pub mutations: Vec<Mutation>,
    /// CRC32C checksum of the serialized payload
    pub checksum: u32,
}

impl CommitRecord {
    /// Create a new commit record
    pub fn new(txn_id: u64, root_page_id: u64, mutations: Vec<Mutation>) -> Self {
        let checksum = 0; // Will be calculated by serialize()
        CommitRecord {
            txn_id,
            root_page_id,
            mutations,
            checksum,
        }
    }

    /// Calculate CRC32C checksum of the serialized payload
    pub fn calculate_payload_checksum(&self) -> u32 {
        let mut hasher = checksum::hasher();

        // Hash commit payload header
        let header = CommitPayloadHeader::new(self.txn_id, self.root_page_id, self.mutations.len() as u32);
        hasher.update(&header.to_bytes());

        // Hash each mutation
        for mutation in &self.mutations {
            let encoded = mutation.encode().unwrap();
            hasher.update(&encoded.to_bytes());
        }

        hasher.finalize()
    }

    /// Validate checksum
    pub fn validate_checksum(&self) -> bool {
        let calculated = self.calculate_payload_checksum();
        calculated == self.checksum
    }

    /// Get transaction ID
    pub fn txn_id(&self) -> u64 {
        self.txn_id
    }

    /// Get root page ID
    pub fn root_page_id(&self) -> u64 {
        self.root_page_id
    }

    /// Get mutations
    pub fn mutations(&self) -> &[Mutation] {
        &self.mutations
    }

    /// Get checksum
    pub fn checksum(&self) -> u32 {
        self.checksum
    }

    /// Serialize to payload bytes
    pub fn serialize_payload(&self) -> Vec<u8> {
        let mut buf = Vec::new();

        // Serialize commit header
        let header = CommitPayloadHeader::new(self.txn_id, self.root_page_id, self.mutations.len() as u32);
        buf.extend_from_slice(&header.to_bytes());

        // Serialize mutations
        for mutation in &self.mutations {
            let encoded = mutation.encode().unwrap();
            buf.extend_from_slice(&encoded.to_bytes());
        }

        // Calculate and update checksum
        let checksum = {
            let mut hasher = checksum::hasher();
            hasher.update(&buf);
            hasher.finalize()
        };

        buf
    }

    /// Deserialize from payload bytes
    pub fn deserialize_payload(txn_id: u64, data: &[u8]) -> Result<Self> {
        // Parse commit header
        let header = CommitPayloadHeader::from_bytes(data)?;
        header.validate()?;

        // Verify txn_id matches
        if header.txn_id != txn_id {
            return Err(Error::Validation(ValidationError::Generic(
                "Transaction ID mismatch".to_string(),
            )));
        }

        // Parse operations
        let mut mutations = Vec::new();
        let mut offset = COMMIT_HEADER_SIZE;

        for _ in 0..header.op_count {
            // Read operation size from key_len and val_len fields
            if offset + 8 > data.len() {
                return Err(Error::Validation(ValidationError::Generic(
                    "Operation header truncated".to_string(),
                )));
            }

            let key_len = LittleEndian::read_u16(&data[offset + 2..offset + 4]) as usize;
            let val_len = LittleEndian::read_u32(&data[offset + 4..offset + 8]) as usize;
            let op_size = 8 + key_len + val_len;

            if offset + op_size > data.len() {
                return Err(Error::Validation(ValidationError::Generic(
                    "Operation data truncated".to_string(),
                )));
            }

            let encoded = EncodedOperation::from_bytes(&data[offset..offset + op_size])?;
            let mutation = Mutation::try_from(encoded)?;
            mutations.push(mutation);

            offset += op_size;
        }

        // Calculate checksum
        let checksum = {
            let mut hasher = checksum::hasher();
            hasher.update(&data[..offset]);
            hasher.finalize()
        };

        Ok(CommitRecord {
            txn_id: header.txn_id,
            root_page_id: header.root_page_id,
            mutations,
            checksum,
        })
    }
}

impl fmt::Display for CommitRecord {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            f,
            "CommitRecord(txn_id={}, root_page_id={}, mutations={}, checksum=0x{:08x})",
            self.txn_id,
            self.root_page_id,
            self.mutations.len(),
            self.checksum
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_commit_payload_header_serialization() {
        let header = CommitPayloadHeader::new(123, 456, 2);

        let bytes = header.to_bytes();
        let decoded = CommitPayloadHeader::from_bytes(&bytes).unwrap();

        assert_eq!(decoded.commit_magic, header.commit_magic);
        assert_eq!(decoded.txn_id, header.txn_id);
        assert_eq!(decoded.root_page_id, header.root_page_id);
        assert_eq!(decoded.op_count, header.op_count);
    }

    #[test]
    fn test_commit_payload_header_validation() {
        // Valid header
        let header = CommitPayloadHeader::new(123, 456, 100);
        assert!(header.validate().is_ok());

        // Invalid magic
        let mut invalid = header;
        invalid.commit_magic = 0xDEADBEEF;
        assert!(invalid.validate().is_err());

        // Invalid reserved field
        let mut invalid = header;
        invalid.reserved = 1;
        assert!(invalid.validate().is_err());

        // Too many operations
        let mut invalid = header;
        invalid.op_count = MAX_OPERATIONS_PER_COMMIT + 1;
        assert!(invalid.validate().is_err());
    }

    #[test]
    fn test_encoded_operation_put() {
        let key = vec![1, 2, 3, 4];
        let value = vec![5, 6, 7, 8, 9];

        let op = EncodedOperation::new_put(key.clone(), value.clone()).unwrap();

        assert_eq!(op.op_type, OperationType::Put);
        assert_eq!(op.key_bytes, key);
        assert_eq!(op.val_bytes, Some(value));
        assert_eq!(op.key_len, 4);
        assert_eq!(op.val_len, 5);
        assert_eq!(op.size(), 8 + 4 + 5);
    }

    #[test]
    fn test_encoded_operation_delete() {
        let key = vec![1, 2, 3, 4];

        let op = EncodedOperation::new_delete(key.clone()).unwrap();

        assert_eq!(op.op_type, OperationType::Delete);
        assert_eq!(op.key_bytes, key);
        assert_eq!(op.val_bytes, None);
        assert_eq!(op.key_len, 4);
        assert_eq!(op.val_len, 0);
        assert_eq!(op.size(), 8 + 4);
    }

    #[test]
    fn test_encoded_operation_serialization() {
        let key = vec![1, 2, 3, 4];
        let value = vec![5, 6, 7, 8, 9];

        let op = EncodedOperation::new_put(key, value).unwrap();
        let bytes = op.to_bytes();
        let decoded = EncodedOperation::from_bytes(&bytes).unwrap();

        assert_eq!(decoded, op);
    }

    #[test]
    fn test_mutation_put() {
        let key = vec![1, 2, 3];
        let value = vec![4, 5, 6];

        let mutation = Mutation::Put {
            key: key.clone(),
            value: value.clone(),
        };

        assert!(mutation.is_put());
        assert!(!mutation.is_delete());
        assert_eq!(mutation.key(), &key[..]);
        assert_eq!(mutation.value(), Some(&value[..]));
    }

    #[test]
    fn test_mutation_delete() {
        let key = vec![1, 2, 3];

        let mutation = Mutation::Delete {
            key: key.clone(),
        };

        assert!(!mutation.is_put());
        assert!(mutation.is_delete());
        assert_eq!(mutation.key(), &key[..]);
        assert_eq!(mutation.value(), None);
    }

    #[test]
    fn test_commit_record() {
        let mutations = vec![
            Mutation::Put {
                key: vec![1, 2],
                value: vec![3, 4],
            },
            Mutation::Delete {
                key: vec![5, 6],
            },
        ];

        let record = CommitRecord::new(123, 456, mutations);

        assert_eq!(record.txn_id(), 123);
        assert_eq!(record.root_page_id(), 456);
        assert_eq!(record.mutations().len(), 2);
    }

    #[test]
    fn test_commit_record_checksum() {
        let mutations = vec![
            Mutation::Put {
                key: vec![1, 2],
                value: vec![3, 4],
            },
        ];

        let record = CommitRecord::new(123, 456, mutations);
        let checksum = record.calculate_payload_checksum();

        // Checksum should be deterministic
        let checksum2 = record.calculate_payload_checksum();
        assert_eq!(checksum, checksum2);
    }

    #[test]
    fn test_operation_type_conversion() {
        assert_eq!(OperationType::from_u8(0), Some(OperationType::Put));
        assert_eq!(OperationType::from_u8(1), Some(OperationType::Delete));
        assert_eq!(OperationType::from_u8(255), None);

        assert_eq!(OperationType::Put.to_u8(), 0);
        assert_eq!(OperationType::Delete.to_u8(), 1);
    }

    #[test]
    fn test_size_limits() {
        // Key too large
        let large_key = vec![0u8; (MAX_KEY_SIZE + 1) as usize];
        assert!(EncodedOperation::new_put(large_key, vec![1]).is_err());

        // Value too large
        let large_value = vec![0u8; (MAX_VALUE_SIZE + 1) as usize];
        assert!(EncodedOperation::new_put(vec![1], large_value).is_err());
    }
}
