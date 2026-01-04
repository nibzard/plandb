//! Delta Layer - Uncommitted Change Tracking
//!
//! The delta layer provides a mechanism for tracking uncommitted changes made by
//! a write transaction before they are durably persisted to the B+Tree. This
//! isolation ensures that concurrent readers see a consistent snapshot without
//! blocking on ongoing writes, and that failed transactions can be rolled back
//! without corrupting the tree structure.

use crate::error::{Error, Result, SizeLimitError, ValidationError};
use crate::types::Lsn;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::io::Read;

/// Maximum key size in bytes
pub const MAX_KEY_SIZE: usize = 255;

/// Maximum value size in bytes (16MB - 1)
pub const MAX_VALUE_SIZE: usize = 16_777_215;

/// Maximum number of operations per transaction
pub const MAX_OPERATIONS_PER_TXN: usize = 1000;

/// Maximum delta layer size in bytes (16MB)
pub const MAX_DELTA_SIZE: usize = 16_777_216;

/// Mutation entry overhead (key_len + value_len + lsn + metadata)
const MUTATION_OVERHEAD: usize = 32;

/// Mutation type identifier for Put operations
pub const MUTATION_TYPE_PUT: u8 = 1;

/// Mutation type identifier for Delete operations
pub const MUTATION_TYPE_DELETE: u8 = 2;

/// Statistics about delta layer state
#[derive(Clone, Debug, PartialEq)]
pub struct DeltaStats {
    /// Total number of mutations
    pub mutation_count: usize,
    /// Number of Put mutations
    pub put_count: usize,
    /// Number of Delete mutations
    pub delete_count: usize,
    /// Total bytes occupied by all mutations
    pub total_size: usize,
    /// Size of largest single mutation
    pub largest_mutation: usize,
    /// Mean mutation size
    pub average_mutation_size: f64,
}

/// Single mutation recorded in delta layer
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum MutationEntry {
    /// Insert or update key with new value
    Put {
        /// Mutated key
        key: Vec<u8>,
        /// New value (inline or overflow reference)
        value: Vec<u8>,
        /// Transaction's temporary LSN
        lsn: Lsn,
        /// Total bytes occupied (key + value + overhead)
        size: usize,
    },
    /// Remove key from tree (tombstone)
    Delete {
        /// Key to delete
        key: Vec<u8>,
        /// Transaction's temporary LSN
        lsn: Lsn,
        /// Bytes occupied (key + overhead, no value)
        size: usize,
    },
}

impl MutationEntry {
    /// Get the key for this mutation entry
    pub fn key(&self) -> &[u8] {
        match self {
            MutationEntry::Put { key, .. } => key,
            MutationEntry::Delete { key, .. } => key,
        }
    }

    /// Get the key as a Vec<u8>
    pub fn key_vec(&self) -> Vec<u8> {
        match self {
            MutationEntry::Put { key, .. } => key.clone(),
            MutationEntry::Delete { key, .. } => key.clone(),
        }
    }

    /// Get the size in bytes for this mutation entry
    pub fn size(&self) -> usize {
        match self {
            MutationEntry::Put { size, .. } => *size,
            MutationEntry::Delete { size, .. } => *size,
        }
    }

    /// Get the LSN for this mutation entry
    pub fn lsn(&self) -> Lsn {
        match self {
            MutationEntry::Put { lsn, .. } => *lsn,
            MutationEntry::Delete { lsn, .. } => *lsn,
        }
    }

    /// Check if this is a Put mutation
    pub fn is_put(&self) -> bool {
        matches!(self, MutationEntry::Put { .. })
    }

    /// Check if this is a Delete mutation
    pub fn is_delete(&self) -> bool {
        matches!(self, MutationEntry::Delete { .. })
    }
}

/// Delta layer - in-memory buffer for transaction mutations
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct DeltaLayer {
    /// Map from key to mutation entry
    mutations: HashMap<Vec<u8>, MutationEntry>,
    /// Total bytes occupied by mutations
    size: usize,
    /// Number of operations in transaction
    operation_count: usize,
}

impl Default for DeltaLayer {
    fn default() -> Self {
        Self::new()
    }
}

impl DeltaLayer {
    /// Create a new empty delta layer
    pub fn new() -> Self {
        Self {
            mutations: HashMap::new(),
            size: 0,
            operation_count: 0,
        }
    }

    /// Record a Put mutation in delta layer
    pub fn record_put(
        &mut self,
        key: &[u8],
        value: &[u8],
        lsn: Lsn,
    ) -> Result<()> {
        // Validate key length
        if key.len() > MAX_KEY_SIZE {
            return Err(Error::SizeLimit(SizeLimitError::KeyTooLarge {
                size: key.len(),
                max: MAX_KEY_SIZE,
            }));
        }

        // Validate value length
        if value.len() > MAX_VALUE_SIZE {
            return Err(Error::SizeLimit(SizeLimitError::ValueTooLarge {
                size: value.len(),
                max: MAX_VALUE_SIZE,
            }));
        }

        // Check operation count limit
        if self.operation_count >= MAX_OPERATIONS_PER_TXN {
            return Err(Error::Validation(ValidationError::TooManyOperations {
                count: self.operation_count as u32,
                max: MAX_OPERATIONS_PER_TXN as u32,
            }));
        }

        // Calculate mutation size
        let mutation_size = key.len() + value.len() + MUTATION_OVERHEAD;

        // Check delta size limit
        if self.size + mutation_size > MAX_DELTA_SIZE {
            return Err(Error::SizeLimit(SizeLimitError::BufferTooSmall {
                size: self.size + mutation_size,
                needed: MAX_DELTA_SIZE,
            }));
        }

        // Remove old entry if exists (last-write-wins)
        if let Some(old_entry) = self.mutations.remove(key) {
            self.size -= old_entry.size();
            // Don't decrement operation_count - we're replacing
        } else {
            self.operation_count += 1;
        }

        // Insert new entry
        let entry = MutationEntry::Put {
            key: key.to_vec(),
            value: value.to_vec(),
            lsn,
            size: mutation_size,
        };
        self.mutations.insert(key.to_vec(), entry);
        self.size += mutation_size;

        Ok(())
    }

    /// Record a Delete mutation in delta layer
    pub fn record_delete(&mut self, key: &[u8], lsn: Lsn) -> Result<()> {
        // Validate key length
        if key.len() > MAX_KEY_SIZE {
            return Err(Error::SizeLimit(SizeLimitError::KeyTooLarge {
                size: key.len(),
                max: MAX_KEY_SIZE,
            }));
        }

        // Check operation count limit
        if self.operation_count >= MAX_OPERATIONS_PER_TXN {
            return Err(Error::Validation(ValidationError::TooManyOperations {
                count: self.operation_count as u32,
                max: MAX_OPERATIONS_PER_TXN as u32,
            }));
        }

        // Calculate mutation size (no value for delete)
        let mutation_size = key.len() + MUTATION_OVERHEAD;

        // Remove old entry if exists
        if let Some(old_entry) = self.mutations.remove(key) {
            self.size -= old_entry.size();
            // Don't decrement operation_count - we're replacing
        } else {
            self.operation_count += 1;
        }

        // Insert new delete entry
        let entry = MutationEntry::Delete {
            key: key.to_vec(),
            lsn,
            size: mutation_size,
        };
        self.mutations.insert(key.to_vec(), entry);
        self.size += mutation_size;

        Ok(())
    }

    /// Look up key in delta layer (for transaction-local reads)
    pub fn get(&self, key: &[u8]) -> Option<&MutationEntry> {
        self.mutations.get(key)
    }

    /// Check if key exists in delta layer
    pub fn contains(&self, key: &[u8]) -> bool {
        self.mutations.contains_key(key)
    }

    /// Get the number of mutations in delta layer
    pub fn len(&self) -> usize {
        self.mutations.len()
    }

    /// Check if delta layer is empty
    pub fn is_empty(&self) -> bool {
        self.mutations.is_empty()
    }

    /// Get the total size in bytes
    pub fn size(&self) -> usize {
        self.size
    }

    /// Get the operation count
    pub fn operation_count(&self) -> usize {
        self.operation_count
    }

    /// Get all mutations as an iterator
    pub fn iter(&self) -> impl Iterator<Item = (&Vec<u8>, &MutationEntry)> {
        self.mutations.iter()
    }

    /// Calculate statistics about delta layer state
    pub fn stats(&self) -> DeltaStats {
        let mut put_count = 0;
        let mut delete_count = 0;
        let mut largest_mutation = 0;

        for entry in self.mutations.values() {
            match entry {
                MutationEntry::Put { .. } => put_count += 1,
                MutationEntry::Delete { .. } => delete_count += 1,
            }
            let entry_size = entry.size();
            if entry_size > largest_mutation {
                largest_mutation = entry_size;
            }
        }

        let mutation_count = put_count + delete_count;
        let average_mutation_size = if mutation_count > 0 {
            self.size as f64 / mutation_count as f64
        } else {
            0.0
        };

        DeltaStats {
            mutation_count,
            put_count,
            delete_count,
            total_size: self.size,
            largest_mutation,
            average_mutation_size,
        }
    }

    /// Serialize delta layer to bytes for WAL commit record
    pub fn serialize(&self) -> Vec<u8> {
        let mut buffer = Vec::new();

        // Write operation count
        buffer.extend_from_slice(&(self.mutations.len() as u32).to_le_bytes());

        // Sort mutations by key for deterministic serialization
        let mut sorted: Vec<_> = self.mutations.iter().collect();
        sorted.sort_by(|a, b| a.0.cmp(b.0));

        // Write each mutation
        for (key, entry) in sorted {
            match entry {
                MutationEntry::Put { value, .. } => {
                    buffer.push(MUTATION_TYPE_PUT);
                    buffer.push(key.len() as u8);
                    buffer.extend_from_slice(key);
                    buffer.extend_from_slice(&(value.len() as u32).to_le_bytes());
                    buffer.extend_from_slice(value);
                }
                MutationEntry::Delete { .. } => {
                    buffer.push(MUTATION_TYPE_DELETE);
                    buffer.push(key.len() as u8);
                    buffer.extend_from_slice(key);
                    buffer.extend_from_slice(&0u32.to_le_bytes()); // value_len = 0
                }
            }
        }

        buffer
    }

    /// Deserialize delta layer from WAL commit record (recovery)
    pub fn deserialize(data: &[u8]) -> Result<Self> {
        let mut cursor = &data[..];
        let mut delta = Self::new();

        // Read operation count
        let mut op_count_bytes = [0u8; 4];
        cursor
            .read_exact(&mut op_count_bytes)
            .map_err(|_| Error::Io(crate::error::IoError::IncompleteKey))?;
        let op_count = u32::from_le_bytes(op_count_bytes) as usize;

        // Read each mutation
        for _ in 0..op_count {
            // Mutation type
            let mut type_byte = [0u8; 1];
            cursor
                .read_exact(&mut type_byte)
                .map_err(|_| Error::Io(crate::error::IoError::IncompleteKey))?;
            let mutation_type = type_byte[0];

            // Key length and bytes
            let mut key_len_byte = [0u8; 1];
            cursor
                .read_exact(&mut key_len_byte)
                .map_err(|_| Error::Io(crate::error::IoError::IncompleteKey))?;
            let key_len = key_len_byte[0] as usize;

            let mut key_bytes = vec![0u8; key_len];
            cursor
                .read_exact(&mut key_bytes)
                .map_err(|_| Error::Io(crate::error::IoError::IncompleteKey))?;

            // Value length
            let mut value_len_bytes = [0u8; 4];
            cursor
                .read_exact(&mut value_len_bytes)
                .map_err(|_| Error::Io(crate::error::IoError::IncompleteKey))?;
            let value_len = u32::from_le_bytes(value_len_bytes) as usize;

            match mutation_type {
                MUTATION_TYPE_PUT => {
                    // Put: read value bytes
                    let mut value_bytes = vec![0u8; value_len];
                    cursor
                        .read_exact(&mut value_bytes)
                        .map_err(|_| Error::Io(crate::error::IoError::IncompleteKey))?;

                    // Calculate size
                    let size = key_len + value_len + MUTATION_OVERHEAD;

                    let entry = MutationEntry::Put {
                        key: key_bytes.clone(),
                        value: value_bytes,
                        lsn: Lsn::INITIAL, // Set during recovery
                        size,
                    };
                    delta.mutations.insert(key_bytes, entry);
                    delta.size += size;
                }
                MUTATION_TYPE_DELETE => {
                    // Delete: value_len must be 0
                    if value_len != 0 {
                        return Err(Error::Validation(ValidationError::DeleteHasValue));
                    }

                    // Calculate size
                    let size = key_len + MUTATION_OVERHEAD;

                    let entry = MutationEntry::Delete {
                        key: key_bytes.clone(),
                        lsn: Lsn::INITIAL, // Set during recovery
                        size,
                    };
                    delta.mutations.insert(key_bytes, entry);
                    delta.size += size;
                }
                _ => {
                    return Err(Error::Validation(ValidationError::InvalidOperationType {
                        type_val: mutation_type,
                    }));
                }
            }

            delta.operation_count += 1;
        }

        Ok(delta)
    }

    /// Clear all mutations (for rollback)
    pub fn clear(&mut self) {
        self.mutations.clear();
        self.size = 0;
        self.operation_count = 0;
    }

    /// Convert delta into mutations map (consumes the delta)
    pub fn into_mutations(self) -> HashMap<Vec<u8>, MutationEntry> {
        self.mutations
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_constants() {
        assert_eq!(MAX_KEY_SIZE, 255);
        assert_eq!(MAX_VALUE_SIZE, 16_777_215);
        assert_eq!(MAX_OPERATIONS_PER_TXN, 1000);
        assert_eq!(MAX_DELTA_SIZE, 16_777_216);
        assert_eq!(MUTATION_OVERHEAD, 32);
        assert_eq!(MUTATION_TYPE_PUT, 1);
        assert_eq!(MUTATION_TYPE_DELETE, 2);
    }

    #[test]
    fn test_delta_layer_new() {
        let delta = DeltaLayer::new();
        assert!(delta.is_empty());
        assert_eq!(delta.len(), 0);
        assert_eq!(delta.size(), 0);
        assert_eq!(delta.operation_count(), 0);
    }

    #[test]
    fn test_delta_layer_default() {
        let delta = DeltaLayer::default();
        assert!(delta.is_empty());
        assert_eq!(delta.len(), 0);
    }

    #[test]
    fn test_record_put() {
        let mut delta = DeltaLayer::new();
        let key = b"test_key";
        let value = b"test_value";
        let lsn = Lsn::new(100);

        delta
            .record_put(key, value, lsn)
            .expect("record_put should succeed");

        assert_eq!(delta.len(), 1);
        assert_eq!(delta.operation_count(), 1);
        assert!(delta.contains(key));

        let entry = delta.get(key).expect("key should exist");
        assert!(entry.is_put());
        assert_eq!(entry.key(), key);
        assert_eq!(entry.lsn(), lsn);
    }

    #[test]
    fn test_record_delete() {
        let mut delta = DeltaLayer::new();
        let key = b"test_key";
        let lsn = Lsn::new(100);

        delta
            .record_delete(key, lsn)
            .expect("record_delete should succeed");

        assert_eq!(delta.len(), 1);
        assert_eq!(delta.operation_count(), 1);
        assert!(delta.contains(key));

        let entry = delta.get(key).expect("key should exist");
        assert!(entry.is_delete());
        assert_eq!(entry.key(), key);
        assert_eq!(entry.lsn(), lsn);
    }

    #[test]
    fn test_record_put_key_too_large() {
        let mut delta = DeltaLayer::new();
        let key = vec![0u8; MAX_KEY_SIZE + 1];
        let value = b"value";
        let lsn = Lsn::new(100);

        let result = delta.record_put(&key, value, lsn);
        assert!(result.is_err());
        match result.unwrap_err() {
            Error::SizeLimit(SizeLimitError::KeyTooLarge { size, .. }) => {
                assert_eq!(size, MAX_KEY_SIZE + 1);
            }
            _ => panic!("Expected KeyTooLarge error"),
        }
    }

    #[test]
    fn test_record_put_value_too_large() {
        let mut delta = DeltaLayer::new();
        let key = b"key";
        let value = vec![0u8; MAX_VALUE_SIZE + 1];
        let lsn = Lsn::new(100);

        let result = delta.record_put(key, &value, lsn);
        assert!(result.is_err());
        match result.unwrap_err() {
            Error::SizeLimit(SizeLimitError::ValueTooLarge { size, .. }) => {
                assert_eq!(size, MAX_VALUE_SIZE + 1);
            }
            _ => panic!("Expected ValueTooLarge error"),
        }
    }

    #[test]
    fn test_record_put_too_many_operations() {
        let mut delta = DeltaLayer::new();

        // Add maximum operations
        for i in 0..MAX_OPERATIONS_PER_TXN {
            let key = format!("key_{}", i).as_bytes().to_vec();
            delta
                .record_put(&key, b"value", Lsn::new(i as u64))
                .expect("record_put should succeed");
        }

        // Try to add one more - should fail
        let result = delta.record_put(b"extra_key", b"value", Lsn::new(1000));
        assert!(result.is_err());
        match result.unwrap_err() {
            Error::Validation(ValidationError::TooManyOperations { count, .. }) => {
                assert_eq!(count as usize, MAX_OPERATIONS_PER_TXN);
            }
            _ => panic!("Expected TooManyOperations error"),
        }
    }

    #[test]
    fn test_record_put_delta_too_large() {
        let mut delta = DeltaLayer::new();

        // Create a delta that's almost at the limit
        let key = b"large_key";
        let value_size = MAX_DELTA_SIZE - key.len() - MUTATION_OVERHEAD;
        let value = vec![0u8; value_size];

        delta
            .record_put(key, &value, Lsn::new(1))
            .expect("first put should succeed");

        // Try to add more - should fail (even a small put would exceed limit)
        let result = delta.record_put(b"extra", b"value", Lsn::new(2));
        assert!(result.is_err());
        match result.unwrap_err() {
            Error::SizeLimit(SizeLimitError::BufferTooSmall { .. }) => {
                // Expected error
            }
            _ => panic!("Expected BufferTooSmall error"),
        }
    }

    #[test]
    fn test_last_write_wins() {
        let mut delta = DeltaLayer::new();
        let key = b"test_key";

        // First put
        delta
            .record_put(key, b"value1", Lsn::new(1))
            .expect("first put should succeed");
        assert_eq!(delta.len(), 1);
        assert_eq!(delta.operation_count(), 1);

        // Second put on same key (should replace)
        delta
            .record_put(key, b"value2", Lsn::new(2))
            .expect("second put should succeed");
        assert_eq!(delta.len(), 1);
        assert_eq!(delta.operation_count(), 1); // Not incremented

        let entry = delta.get(key).expect("key should exist");
        if let MutationEntry::Put { value, .. } = entry {
            assert_eq!(value, b"value2");
        } else {
            panic!("Expected Put entry");
        }
    }

    #[test]
    fn test_put_then_delete_same_key() {
        let mut delta = DeltaLayer::new();
        let key = b"test_key";

        // Put
        delta
            .record_put(key, b"value", Lsn::new(1))
            .expect("put should succeed");

        // Delete (should replace)
        delta
            .record_delete(key, Lsn::new(2))
            .expect("delete should succeed");

        assert_eq!(delta.len(), 1);
        assert_eq!(delta.operation_count(), 1);

        let entry = delta.get(key).expect("key should exist");
        assert!(entry.is_delete());
    }

    #[test]
    fn test_get_not_found() {
        let delta = DeltaLayer::new();
        assert!(delta.get(b"nonexistent").is_none());
        assert!(!delta.contains(b"nonexistent"));
    }

    #[test]
    fn test_stats() {
        let mut delta = DeltaLayer::new();

        // Add some mutations
        delta.record_put(b"key1", b"value1", Lsn::new(1)).unwrap();
        delta.record_put(b"key2", b"value2", Lsn::new(2)).unwrap();
        delta.record_delete(b"key3", Lsn::new(3)).unwrap();

        let stats = delta.stats();
        assert_eq!(stats.mutation_count, 3);
        assert_eq!(stats.put_count, 2);
        assert_eq!(stats.delete_count, 1);
        assert!(stats.total_size > 0);
        assert!(stats.largest_mutation > 0);
        assert!(stats.average_mutation_size > 0.0);
    }

    #[test]
    fn test_stats_empty() {
        let delta = DeltaLayer::new();
        let stats = delta.stats();
        assert_eq!(stats.mutation_count, 0);
        assert_eq!(stats.put_count, 0);
        assert_eq!(stats.delete_count, 0);
        assert_eq!(stats.total_size, 0);
        assert_eq!(stats.largest_mutation, 0);
        assert_eq!(stats.average_mutation_size, 0.0);
    }

    #[test]
    fn test_serialize_put() {
        let mut delta = DeltaLayer::new();
        delta
            .record_put(b"key1", b"value1", Lsn::new(1))
            .unwrap();
        delta
            .record_put(b"key2", b"value2", Lsn::new(2))
            .unwrap();

        let serialized = delta.serialize();

        // Should have: count (4) + type (1) + key_len (1) + key (4) + value_len (4) + value (6)
        // + type (1) + key_len (1) + key (4) + value_len (4) + value (6)
        // = 4 + 16 + 16 = 36 bytes
        assert_eq!(serialized.len(), 36);

        // Check operation count
        assert_eq!(
            u32::from_le_bytes([serialized[0], serialized[1], serialized[2], serialized[3]]),
            2
        );
    }

    #[test]
    fn test_serialize_delete() {
        let mut delta = DeltaLayer::new();
        delta.record_delete(b"key1", Lsn::new(1)).unwrap();
        delta.record_delete(b"key2", Lsn::new(2)).unwrap();

        let serialized = delta.serialize();

        // Should have: count (4) + type (1) + key_len (1) + key (4) + value_len (4)
        // + type (1) + key_len (1) + key (4) + value_len (4)
        // = 4 + 10 + 10 = 24 bytes
        assert_eq!(serialized.len(), 24);
    }

    #[test]
    fn test_deserialize_put() {
        let mut delta = DeltaLayer::new();
        delta
            .record_put(b"key1", b"value1", Lsn::new(1))
            .unwrap();

        let serialized = delta.serialize();
        let deserialized = DeltaLayer::deserialize(&serialized).unwrap();

        assert_eq!(deserialized.len(), 1);
        assert!(deserialized.contains(b"key1"));

        let entry = deserialized.get(b"key1").unwrap();
        assert!(entry.is_put());
        if let MutationEntry::Put { value, .. } = entry {
            assert_eq!(value, b"value1");
        } else {
            panic!("Expected Put entry");
        }
    }

    #[test]
    fn test_deserialize_delete() {
        let mut delta = DeltaLayer::new();
        delta.record_delete(b"key1", Lsn::new(1)).unwrap();

        let serialized = delta.serialize();
        let deserialized = DeltaLayer::deserialize(&serialized).unwrap();

        assert_eq!(deserialized.len(), 1);
        assert!(deserialized.contains(b"key1"));

        let entry = deserialized.get(b"key1").unwrap();
        assert!(entry.is_delete());
    }

    #[test]
    fn test_deserialize_truncated() {
        let data = [0u8; 2]; // Too short for operation count
        let result = DeltaLayer::deserialize(&data);
        assert!(result.is_err());
        match result.unwrap_err() {
            Error::Io(crate::error::IoError::IncompleteKey) => {}
            _ => panic!("Expected IncompleteKey error"),
        }
    }

    #[test]
    fn test_deserialize_invalid_mutation_type() {
        let mut data = Vec::new();
        data.extend_from_slice(&1u32.to_le_bytes()); // 1 operation
        data.push(99u8); // Invalid mutation type
        data.push(4u8); // key_len
        data.extend_from_slice(b"test");
        data.extend_from_slice(&0u32.to_le_bytes()); // value_len

        let result = DeltaLayer::deserialize(&data);
        assert!(result.is_err());
        match result.unwrap_err() {
            Error::Validation(ValidationError::InvalidOperationType { type_val: 99 }) => {}
            _ => panic!("Expected InvalidOperationType error"),
        }
    }

    #[test]
    fn test_deserialize_invalid_delete_value() {
        let mut data = Vec::new();
        data.extend_from_slice(&1u32.to_le_bytes()); // 1 operation
        data.push(MUTATION_TYPE_DELETE); // Delete type
        data.push(4u8); // key_len
        data.extend_from_slice(b"test");
        data.extend_from_slice(&10u32.to_le_bytes()); // value_len (should be 0)

        let result = DeltaLayer::deserialize(&data);
        assert!(result.is_err());
        match result.unwrap_err() {
            Error::Validation(ValidationError::DeleteHasValue) => {}
            _ => panic!("Expected DeleteHasValue error"),
        }
    }

    #[test]
    fn test_serialize_round_trip() {
        let mut delta = DeltaLayer::new();
        delta
            .record_put(b"key1", b"value1", Lsn::new(1))
            .unwrap();
        delta.record_delete(b"key2", Lsn::new(2)).unwrap();
        delta
            .record_put(b"key3", b"value3", Lsn::new(3))
            .unwrap();

        let serialized = delta.serialize();
        let deserialized = DeltaLayer::deserialize(&serialized).unwrap();

        assert_eq!(deserialized.len(), 3);
        assert!(deserialized.contains(b"key1"));
        assert!(deserialized.contains(b"key2"));
        assert!(deserialized.contains(b"key3"));

        assert!(deserialized.get(b"key1").unwrap().is_put());
        assert!(deserialized.get(b"key2").unwrap().is_delete());
        assert!(deserialized.get(b"key3").unwrap().is_put());
    }

    #[test]
    fn test_clear() {
        let mut delta = DeltaLayer::new();
        delta
            .record_put(b"key1", b"value1", Lsn::new(1))
            .unwrap();
        delta.record_delete(b"key2", Lsn::new(2)).unwrap();

        assert_eq!(delta.len(), 2);
        // key1 (4) + value1 (6) + overhead + key2 (4) + overhead
        let expected_size = 4 + 6 + MUTATION_OVERHEAD + 4 + MUTATION_OVERHEAD;
        assert_eq!(delta.size(), expected_size);

        delta.clear();

        assert!(delta.is_empty());
        assert_eq!(delta.size(), 0);
        assert_eq!(delta.operation_count(), 0);
    }

    #[test]
    fn test_into_mutations() {
        let mut delta = DeltaLayer::new();
        delta
            .record_put(b"key1", b"value1", Lsn::new(1))
            .unwrap();
        delta.record_delete(b"key2", Lsn::new(2)).unwrap();

        let mutations = delta.into_mutations();
        assert_eq!(mutations.len(), 2);
        assert!(mutations.contains_key(&b"key1".to_vec()));
        assert!(mutations.contains_key(&b"key2".to_vec()));
    }

    #[test]
    fn test_mutation_entry_key() {
        let put_entry = MutationEntry::Put {
            key: vec![1, 2, 3],
            value: vec![4, 5, 6],
            lsn: Lsn::new(1),
            size: 100,
        };
        assert_eq!(put_entry.key(), &[1, 2, 3]);

        let delete_entry = MutationEntry::Delete {
            key: vec![7, 8, 9],
            lsn: Lsn::new(2),
            size: 50,
        };
        assert_eq!(delete_entry.key(), &[7, 8, 9]);
    }

    #[test]
    fn test_mutation_entry_size() {
        let put_entry = MutationEntry::Put {
            key: vec![1],
            value: vec![2],
            lsn: Lsn::new(1),
            size: 100,
        };
        assert_eq!(put_entry.size(), 100);

        let delete_entry = MutationEntry::Delete {
            key: vec![1],
            lsn: Lsn::new(2),
            size: 50,
        };
        assert_eq!(delete_entry.size(), 50);
    }

    #[test]
    fn test_mutation_entry_lsn() {
        let put_entry = MutationEntry::Put {
            key: vec![1],
            value: vec![2],
            lsn: Lsn::new(100),
            size: 100,
        };
        assert_eq!(put_entry.lsn(), Lsn::new(100));

        let delete_entry = MutationEntry::Delete {
            key: vec![1],
            lsn: Lsn::new(200),
            size: 50,
        };
        assert_eq!(delete_entry.lsn(), Lsn::new(200));
    }

    #[test]
    fn test_mutation_entry_is_put() {
        let put_entry = MutationEntry::Put {
            key: vec![1],
            value: vec![2],
            lsn: Lsn::new(1),
            size: 100,
        };
        assert!(put_entry.is_put());
        assert!(!put_entry.is_delete());

        let delete_entry = MutationEntry::Delete {
            key: vec![1],
            lsn: Lsn::new(2),
            size: 50,
        };
        assert!(!delete_entry.is_put());
        assert!(delete_entry.is_delete());
    }

    #[test]
    fn test_iter() {
        let mut delta = DeltaLayer::new();
        delta
            .record_put(b"key1", b"value1", Lsn::new(1))
            .unwrap();
        delta.record_delete(b"key2", Lsn::new(2)).unwrap();

        let mut count = 0;
        for (key, entry) in delta.iter() {
            assert!(key == b"key1" || key == b"key2");
            assert!(entry.is_put() || entry.is_delete());
            count += 1;
        }
        assert_eq!(count, 2);
    }

    #[test]
    fn test_empty_key() {
        let mut delta = DeltaLayer::new();
        delta
            .record_put(b"", b"value", Lsn::new(1))
            .expect("empty key should be allowed");
        assert!(delta.contains(b""));
    }

    #[test]
    fn test_empty_value() {
        let mut delta = DeltaLayer::new();
        delta
            .record_put(b"key", b"", Lsn::new(1))
            .expect("empty value should be allowed");

        let entry = delta.get(b"key").unwrap();
        if let MutationEntry::Put { value, .. } = entry {
            assert_eq!(value, b"");
        } else {
            panic!("Expected Put entry");
        }
    }

    #[test]
    fn test_max_key_size_boundary() {
        let mut delta = DeltaLayer::new();
        let key = vec![b'X'; MAX_KEY_SIZE];
        delta
            .record_put(&key, b"value", Lsn::new(1))
            .expect("max size key should be allowed");
        assert!(delta.contains(&key));
    }

    #[test]
    fn test_max_value_size_boundary() {
        let mut delta = DeltaLayer::new();
        // Use a value that fits both value size limit and delta size limit
        // Account for key len and overhead: MAX_DELTA_SIZE - key.len() - MUTATION_OVERHEAD
        let key = b"key";
        let value_size = MAX_VALUE_SIZE.min(MAX_DELTA_SIZE - key.len() - MUTATION_OVERHEAD);
        let value = vec![b'Y'; value_size];
        delta
            .record_put(key, &value, Lsn::new(1))
            .expect("max size value should be allowed");
    }

    #[test]
    fn test_serialization_ordering() {
        let mut delta = DeltaLayer::new();
        delta
            .record_put(b"key3", b"value3", Lsn::new(3))
            .unwrap();
        delta
            .record_put(b"key1", b"value1", Lsn::new(1))
            .unwrap();
        delta
            .record_put(b"key2", b"value2", Lsn::new(2))
            .unwrap();

        let serialized = delta.serialize();
        let deserialized = DeltaLayer::deserialize(&serialized).unwrap();

        // Verify that deserialization preserves the sorted order
        let mut keys: Vec<_> = deserialized.iter().map(|(k, _)| k.clone()).collect();
        keys.sort(); // Sort for comparison since HashMap doesn't guarantee order
        assert_eq!(
            keys,
            vec![b"key1".to_vec(), b"key2".to_vec(), b"key3".to_vec()]
        );
    }

    #[test]
    fn test_delta_stats_accuracy() {
        let mut delta = DeltaLayer::new();
        delta
            .record_put(b"key1", b"value1", Lsn::new(1))
            .unwrap();
        delta.record_delete(b"key2", Lsn::new(2)).unwrap();

        let stats = delta.stats();

        // Verify mutation count
        assert_eq!(stats.mutation_count, 2);

        // Verify total size matches delta size
        assert_eq!(stats.total_size, delta.size());

        // Verify average size calculation
        let expected_avg = delta.size() as f64 / 2.0;
        assert!((stats.average_mutation_size - expected_avg).abs() < 0.01);
    }

    #[test]
    fn test_size_calculation() {
        let mut delta = DeltaLayer::new();
        let key = b"test_key";
        let value = b"test_value";

        delta
            .record_put(key, value, Lsn::new(1))
            .unwrap();

        let expected_size = key.len() + value.len() + MUTATION_OVERHEAD;
        assert_eq!(delta.size(), expected_size);

        let entry = delta.get(key).unwrap();
        assert_eq!(entry.size(), expected_size);
    }
}
