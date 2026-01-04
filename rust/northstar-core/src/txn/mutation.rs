//! Mutation types for transaction operations.
//!
//! Represents single database operations (Put, Delete) that can be
//! buffered within a transaction and applied atomically.

use crate::error::{Result, SizeLimitError, ValidationError};
use serde::{Deserialize, Serialize};

/// Represents a single database operation within a transaction.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum Mutation {
    /// Insert or update a key-value pair.
    Put {
        key: Vec<u8>,
        value: Vec<u8>,
    },
    /// Delete a key from the database.
    Delete {
        key: Vec<u8>,
    },
}

impl Mutation {
    /// Get the key associated with this mutation.
    pub fn get_key(&self) -> &[u8] {
        match self {
            Mutation::Put { key, .. } => key,
            Mutation::Delete { key } => key,
        }
    }

    /// Get the value if this is a Put mutation.
    pub fn get_value(&self) -> Option<&[u8]> {
        match self {
            Mutation::Put { value, .. } => Some(value),
            Mutation::Delete { .. } => None,
        }
    }

    /// Check if this is a Put mutation.
    pub fn is_put(&self) -> bool {
        matches!(self, Mutation::Put { .. })
    }

    /// Check if this is a Delete mutation.
    pub fn is_delete(&self) -> bool {
        matches!(self, Mutation::Delete { .. })
    }

    /// Calculate the size of this mutation in bytes.
    pub fn size(&self) -> usize {
        match self {
            Mutation::Put { key, value } => key.len() + value.len(),
            Mutation::Delete { key } => key.len(),
        }
    }

    /// Validate this mutation.
    pub fn validate(&self) -> Result<()> {
        let key = self.get_key();

        // Key must be non-empty
        if key.is_empty() {
            return Err(ValidationError::Generic("Key cannot be empty".to_string()).into());
        }

        // Key size limit
        if key.len() > super::MAX_KEY_SIZE {
            return Err(SizeLimitError::KeyTooLarge {
                size: key.len(),
                max: super::MAX_KEY_SIZE,
            }
            .into());
        }

        // Value size limit (only for Put)
        if let Some(value) = self.get_value() {
            if value.len() > super::MAX_VALUE_SIZE {
                return Err(SizeLimitError::ValueTooLarge {
                    size: value.len(),
                    max: super::MAX_VALUE_SIZE,
                }
                .into());
            }
        }

        Ok(())
    }

    /// Create a new Put mutation.
    pub fn put(key: Vec<u8>, value: Vec<u8>) -> Self {
        Self::Put { key, value }
    }

    /// Create a new Delete mutation.
    pub fn delete(key: Vec<u8>) -> Self {
        Self::Delete { key }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use super::super::{MAX_KEY_SIZE, MAX_VALUE_SIZE};

    #[test]
    fn test_mutation_put() {
        let mutation = Mutation::put(b"key".to_vec(), b"value".to_vec());
        assert!(mutation.is_put());
        assert!(!mutation.is_delete());
        assert_eq!(mutation.get_key(), b"key");
        assert_eq!(mutation.get_value(), Some(&b"value"[..]));
        assert_eq!(mutation.size(), 8); // 3 + 5
    }

    #[test]
    fn test_mutation_delete() {
        let mutation = Mutation::delete(b"key".to_vec());
        assert!(!mutation.is_put());
        assert!(mutation.is_delete());
        assert_eq!(mutation.get_key(), b"key");
        assert_eq!(mutation.get_value(), None);
        assert_eq!(mutation.size(), 3);
    }

    #[test]
    fn test_mutation_validate() {
        // Valid mutation
        let mutation = Mutation::put(b"key".to_vec(), b"value".to_vec());
        assert!(mutation.validate().is_ok());

        // Empty key
        let mutation = Mutation::put(b"".to_vec(), b"value".to_vec());
        assert!(mutation.validate().is_err());

        // Key too large
        let large_key = vec![0u8; MAX_KEY_SIZE + 1];
        let mutation = Mutation::put(large_key, b"value".to_vec());
        assert!(mutation.validate().is_err());

        // Value too large
        let large_value = vec![0u8; MAX_VALUE_SIZE + 1];
        let mutation = Mutation::put(b"key".to_vec(), large_value);
        assert!(mutation.validate().is_err());
    }
}
