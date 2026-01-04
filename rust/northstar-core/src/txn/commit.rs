//! Commit record for transaction durability.
//!
//! Serializable representation of a transaction that can be written
//! to the WAL for crash recovery.

use crate::types::TransactionId;
use super::Mutation;
use serde::{Deserialize, Serialize};

/// Commit record written to WAL for transaction durability.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CommitRecord {
    /// Transaction identifier.
    pub txn_id: TransactionId,
    /// New B+tree root page ID after applying mutations.
    pub root_page_id: u64,
    /// All mutations in this transaction.
    pub mutations: Vec<Mutation>,
    /// Checksum of all mutations.
    pub checksum: u32,
}

impl CommitRecord {
    /// Create a new commit record.
    pub fn new(txn_id: TransactionId, root_page_id: u64, mutations: Vec<Mutation>) -> Self {
        // Calculate checksum over all mutations
        let checksum = Self::calculate_checksum(&mutations);

        Self {
            txn_id,
            root_page_id,
            mutations,
            checksum,
        }
    }

    /// Calculate checksum over mutations.
    fn calculate_checksum(mutations: &[Mutation]) -> u32 {
        let mut hasher = crate::checksum::Crc32cHasher::new();
        for mutation in mutations {
            // Update hash with mutation bytes
            match mutation {
                Mutation::Put { key, value } => {
                    hasher.update(&[1]); // Put variant marker
                    hasher.update(&(key.len() as u32).to_le_bytes());
                    hasher.update(key);
                    hasher.update(&(value.len() as u32).to_le_bytes());
                    hasher.update(value);
                }
                Mutation::Delete { key } => {
                    hasher.update(&[0]); // Delete variant marker
                    hasher.update(&(key.len() as u32).to_le_bytes());
                    hasher.update(key);
                }
            }
        }
        hasher.finalize()
    }

    /// Verify the checksum of this commit record.
    pub fn verify(&self) -> bool {
        let calculated = Self::calculate_checksum(&self.mutations);
        calculated == self.checksum
    }

    /// Get the number of mutations in this commit record.
    pub fn mutation_count(&self) -> usize {
        self.mutations.len()
    }

    /// Get the total size of all mutations in bytes.
    pub fn total_size(&self) -> usize {
        self.mutations.iter().map(|m| m.size()).sum()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_commit_record_creation() {
        let mutations = vec![
            Mutation::put(b"key1".to_vec(), b"value1".to_vec()),
            Mutation::delete(b"key2".to_vec()),
        ];

        let record = CommitRecord::new(TransactionId::new(1), 100, mutations.clone());

        assert_eq!(record.txn_id.as_u64(), 1);
        assert_eq!(record.root_page_id, 100);
        assert_eq!(record.mutation_count(), 2);
        assert_eq!(record.total_size(), 14); // key1(4) + value1(6) + key2(4)
    }

    #[test]
    fn test_commit_record_checksum() {
        let mutations = vec![
            Mutation::put(b"key1".to_vec(), b"value1".to_vec()),
            Mutation::delete(b"key2".to_vec()),
        ];

        let record = CommitRecord::new(TransactionId::new(1), 100, mutations);

        // Same mutations should produce same checksum
        assert!(record.verify());

        // Corrupted mutations should fail verification
        let mut corrupted = record.clone();
        corrupted.mutations.push(Mutation::put(b"key3".to_vec(), b"value3".to_vec()));
        assert!(!corrupted.verify());
    }

    // TODO: Add serialization tests once bincode is added to dependencies
    // #[test]
    // fn test_commit_record_serialize() {
    //     let mutations = vec![
    //         Mutation::put(b"key1".to_vec(), b"value1".to_vec()),
    //     ];
    //
    //     let record = CommitRecord::new(TransactionId::new(1), 100, mutations);
    //
    //     // Serialize and deserialize
    //     let bytes = bincode::serialize(&record).expect("Failed to serialize");
    //     let deserialized: CommitRecord = bincode::deserialize(&bytes).expect("Failed to deserialize");
    //
    //     assert_eq!(deserialized.txn_id, record.txn_id);
    //     assert_eq!(deserialized.root_page_id, record.root_page_id);
    //     assert_eq!(deserialized.mutations.len(), record.mutations.len());
    //     assert!(deserialized.verify());
    // }
}
