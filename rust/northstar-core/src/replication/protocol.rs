//! Replication protocol message types.
//!
//! Defines the wire format messages sent between primary and replica nodes.

use crate::txn::CommitRecord;
use serde::{Deserialize, Serialize};

/// Type of replication message.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum MessageType {
    /// Periodic keepalive with current LSN.
    Heartbeat = 0,

    /// Actual commit record data.
    CommitRecord = 1,

    /// Full snapshot for bootstrap.
    Snapshot = 2,

    /// Error notification with error code.
    Error = 3,
}

impl MessageType {
    /// Get the message type from a u16 value.
    pub fn from_u16(value: u16) -> Option<Self> {
        match value {
            0 => Some(Self::Heartbeat),
            1 => Some(Self::CommitRecord),
            2 => Some(Self::Snapshot),
            3 => Some(Self::Error),
            _ => None,
        }
    }

    /// Get the u16 value of this message type.
    pub const fn as_u16(self) -> u16 {
        self as u16
    }

    /// Check if this message type requires a payload.
    pub const fn requires_payload(self) -> bool {
        matches!(self, Self::CommitRecord | Self::Snapshot | Self::Error)
    }

    /// Check if this message type can be sent in any state.
    pub const fn is_always_allowed(self) -> bool {
        matches!(self, Self::Heartbeat | Self::Error)
    }
}

/// Wire format message sent between primary and replica.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ReplicationMessage {
    /// Protocol version for compatibility negotiation.
    pub version: u16,

    /// Message type enum.
    pub message_type: MessageType,

    /// Monotonically increasing sequence number for ordering.
    pub sequence: u64,

    /// Optional commit record (present for CommitRecord messages).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub commit_record: Option<Box<CommitRecord>>,

    /// Checksum for end-to-end integrity validation.
    pub checksum: u64,
}

impl ReplicationMessage {
    /// Create a new heartbeat message.
    pub fn heartbeat(sequence: u64) -> Self {
        Self {
            version: crate::replication::PROTOCOL_VERSION,
            message_type: MessageType::Heartbeat,
            sequence,
            commit_record: None,
            checksum: 0,
        }
    }

    /// Create a new commit record message.
    pub fn commit_record(sequence: u64, record: CommitRecord) -> Self {
        let checksum = Self::calculate_checksum(&record);
        Self {
            version: crate::replication::PROTOCOL_VERSION,
            message_type: MessageType::CommitRecord,
            sequence,
            commit_record: Some(Box::new(record)),
            checksum,
        }
    }

    /// Create a new snapshot message.
    pub fn snapshot(sequence: u64, snapshot_data: Vec<u8>) -> Self {
        let checksum = Self::calculate_data_checksum(&snapshot_data);
        Self {
            version: crate::replication::PROTOCOL_VERSION,
            message_type: MessageType::Snapshot,
            sequence,
            commit_record: None,
            checksum,
        }
    }

    /// Create a new error message.
    pub fn error(sequence: u64, error_code: u32, error_message: String) -> Self {
        // Encode error into checksum for simplicity
        let checksum = (error_code as u64) | ((error_message.len() as u64) << 32);
        Self {
            version: crate::replication::PROTOCOL_VERSION,
            message_type: MessageType::Error,
            sequence,
            commit_record: None,
            checksum,
        }
    }

    /// Calculate checksum for a commit record.
    fn calculate_checksum(record: &CommitRecord) -> u64 {
        // Use the commit record's checksum plus additional validation
        // For now, we combine the existing checksum with the txn_id and root_page_id
        let base = record.checksum as u64;
        let txn_part = record.txn_id.as_u64();
        let root_part = record.root_page_id;

        // Simple hash combination
        base ^ txn_part.wrapping_mul(31).wrapping_add(root_part)
    }

    /// Calculate checksum for raw data.
    fn calculate_data_checksum(data: &[u8]) -> u64 {
        use std::collections::hash_map::DefaultHasher;
        use std::hash::Hasher;

        let mut hasher = DefaultHasher::new();
        hasher.write(data);
        hasher.finish()
    }

    /// Validate the message checksum.
    pub fn validate_checksum(&self) -> bool {
        match self.message_type {
            MessageType::CommitRecord => {
                if let Some(record) = &self.commit_record {
                    self.checksum == Self::calculate_checksum(record)
                } else {
                    false
                }
            }
            MessageType::Heartbeat | MessageType::Snapshot | MessageType::Error => true,
        }
    }

    /// Get the approximate size of this message in bytes.
    pub fn size_hint(&self) -> usize {
        let base_size = std::mem::size_of::<Self>();
        match self.message_type {
            MessageType::CommitRecord => {
                // Estimate commit record size
                if let Some(record) = &self.commit_record {
                    base_size + record.mutations.len() * 100 // Rough estimate
                } else {
                    base_size
                }
            }
            MessageType::Snapshot => base_size + 1024, // Estimate
            _ => base_size,
        }
    }

    /// Check if this message requires a payload.
    pub const fn requires_payload(&self) -> bool {
        self.message_type.requires_payload()
    }

    /// Check if this message can be sent in any connection state.
    pub const fn is_always_allowed(&self) -> bool {
        self.message_type.is_always_allowed()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::types::{TransactionId, Lsn};
    use crate::txn::Mutation;

    #[test]
    fn test_message_type_from_u16() {
        assert_eq!(MessageType::from_u16(0), Some(MessageType::Heartbeat));
        assert_eq!(MessageType::from_u16(1), Some(MessageType::CommitRecord));
        assert_eq!(MessageType::from_u16(2), Some(MessageType::Snapshot));
        assert_eq!(MessageType::from_u16(3), Some(MessageType::Error));
        assert_eq!(MessageType::from_u16(99), None);
    }

    #[test]
    fn test_message_type_as_u16() {
        assert_eq!(MessageType::Heartbeat.as_u16(), 0);
        assert_eq!(MessageType::CommitRecord.as_u16(), 1);
        assert_eq!(MessageType::Snapshot.as_u16(), 2);
        assert_eq!(MessageType::Error.as_u16(), 3);
    }

    #[test]
    fn test_message_type_requires_payload() {
        assert!(!MessageType::Heartbeat.requires_payload());
        assert!(MessageType::CommitRecord.requires_payload());
        assert!(MessageType::Snapshot.requires_payload());
        assert!(MessageType::Error.requires_payload());
    }

    #[test]
    fn test_message_type_is_always_allowed() {
        assert!(MessageType::Heartbeat.is_always_allowed());
        assert!(!MessageType::CommitRecord.is_always_allowed());
        assert!(!MessageType::Snapshot.is_always_allowed());
        assert!(MessageType::Error.is_always_allowed());
    }

    #[test]
    fn test_replication_message_heartbeat() {
        let msg = ReplicationMessage::heartbeat(123);
        assert_eq!(msg.version, crate::replication::PROTOCOL_VERSION);
        assert_eq!(msg.message_type, MessageType::Heartbeat);
        assert_eq!(msg.sequence, 123);
        assert!(msg.commit_record.is_none());
        assert_eq!(msg.checksum, 0);
        assert!(!msg.requires_payload());
        assert!(msg.is_always_allowed());
    }

    #[test]
    fn test_replication_message_commit_record() {
        let txn_id = TransactionId::new(1);
        let mutations = vec![
            Mutation::Put {
                key: b"key1".to_vec(),
                value: b"value1".to_vec(),
            },
        ];
        let record = CommitRecord::new(txn_id, 100, mutations);

        let msg = ReplicationMessage::commit_record(456, record.clone());
        assert_eq!(msg.version, crate::replication::PROTOCOL_VERSION);
        assert_eq!(msg.message_type, MessageType::CommitRecord);
        assert_eq!(msg.sequence, 456);
        assert!(msg.commit_record.is_some());
        assert!(msg.requires_payload());
        assert!(!msg.is_always_allowed());

        // Checksum validation
        assert!(msg.validate_checksum());
    }

    #[test]
    fn test_replication_message_snapshot() {
        let data = vec![1, 2, 3, 4, 5];
        let msg = ReplicationMessage::snapshot(789, data.clone());

        assert_eq!(msg.version, crate::replication::PROTOCOL_VERSION);
        assert_eq!(msg.message_type, MessageType::Snapshot);
        assert_eq!(msg.sequence, 789);
        assert!(msg.requires_payload());
    }

    #[test]
    fn test_replication_message_error() {
        let msg = ReplicationMessage::error(999, 404, "Not found".to_string());

        assert_eq!(msg.version, crate::replication::PROTOCOL_VERSION);
        assert_eq!(msg.message_type, MessageType::Error);
        assert_eq!(msg.sequence, 999);
        assert!(msg.is_always_allowed());

        // Checksum encodes error code and message length
        assert_eq!(msg.checksum & 0xFFFFFFFF, 404);
        assert_eq!((msg.checksum >> 32) as usize, "Not found".len());
    }

    #[test]
    fn test_replication_message_validate_checksum() {
        let txn_id = TransactionId::new(1);
        let mutations = vec![
            Mutation::Put {
                key: b"key1".to_vec(),
                value: b"value1".to_vec(),
            },
        ];
        let record = CommitRecord::new(txn_id, 100, mutations);

        let msg = ReplicationMessage::commit_record(1, record);
        assert!(msg.validate_checksum());

        // Heartbeat always validates
        let heartbeat = ReplicationMessage::heartbeat(1);
        assert!(heartbeat.validate_checksum());
    }

    #[test]
    fn test_replication_message_size_hint() {
        let heartbeat = ReplicationMessage::heartbeat(1);
        assert!(heartbeat.size_hint() > 0);

        let txn_id = TransactionId::new(1);
        let mutations = vec![
            Mutation::Put {
                key: b"key1".to_vec(),
                value: b"value1".to_vec(),
            },
        ];
        let record = CommitRecord::new(txn_id, 100, mutations);

        let commit_msg = ReplicationMessage::commit_record(1, record);
        assert!(commit_msg.size_hint() > heartbeat.size_hint());
    }
}
