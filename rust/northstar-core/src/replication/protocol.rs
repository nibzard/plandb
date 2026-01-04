//! Replication protocol message types.
//!
//! Defines the wire format messages sent between primary and replica nodes.

use crate::txn::CommitRecord;
use crate::txn::Mutation;
use crate::types::TransactionId;
use serde::{Deserialize, Serialize};
use std::io::{self, Read, Write, Cursor, BufRead};
use byteorder::{LittleEndian, ReadBytesExt, WriteBytesExt};

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

    /// Connect message from replica to primary.
    Connect = 4,

    /// Accept response from primary to replica.
    Accept = 5,

    /// Acknowledgment from replica to primary.
    Ack = 6,
}

impl MessageType {
    /// Get the message type from a u16 value.
    pub fn from_u16(value: u16) -> Option<Self> {
        match value {
            0 => Some(Self::Heartbeat),
            1 => Some(Self::CommitRecord),
            2 => Some(Self::Snapshot),
            3 => Some(Self::Error),
            4 => Some(Self::Connect),
            5 => Some(Self::Accept),
            6 => Some(Self::Ack),
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

    /// Optional LSN (present in some message types).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub lsn: Option<u64>,

    /// Raw payload bytes for certain message types.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub payload: Option<Vec<u8>>,

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
            lsn: None,
            payload: None,
            checksum: 0,
        }
    }

    /// Create a new commit record message (backward compatible).
    pub fn commit_record(sequence: u64, record: CommitRecord) -> Self {
        let checksum = Self::calculate_checksum(&record);
        Self {
            version: crate::replication::PROTOCOL_VERSION,
            message_type: MessageType::CommitRecord,
            sequence,
            commit_record: Some(Box::new(record)),
            lsn: None,
            payload: None,
            checksum,
        }
    }

    /// Create a new commit record message with serialized bytes.
    pub fn commit_record_bytes(sequence: u64, lsn: u64, record_bytes: bytes::Bytes, checksum: u64) -> Self {
        Self {
            version: crate::replication::PROTOCOL_VERSION,
            message_type: MessageType::CommitRecord,
            sequence,
            commit_record: None,
            lsn: Some(lsn),
            payload: Some(record_bytes.to_vec()),
            checksum,
        }
    }

    /// Create a new connect message (replica to primary).
    pub fn connect(replica_id: u64, start_lsn: u64) -> Self {
        Self {
            version: crate::replication::PROTOCOL_VERSION,
            message_type: MessageType::Connect,
            sequence: replica_id,
            commit_record: None,
            lsn: Some(start_lsn),
            payload: None,
            checksum: 0,
        }
    }

    /// Create a new accept message (primary to replica).
    pub fn accept(current_lsn: u64, protocol_version: u16) -> Self {
        Self {
            version: protocol_version,
            message_type: MessageType::Accept,
            sequence: current_lsn,
            commit_record: None,
            lsn: Some(current_lsn),
            payload: None,
            checksum: 0,
        }
    }

    /// Create a new acknowledgment message (replica to primary).
    pub fn ack(sequence: u64) -> Self {
        Self {
            version: crate::replication::PROTOCOL_VERSION,
            message_type: MessageType::Ack,
            sequence,
            commit_record: None,
            lsn: None,
            payload: None,
            checksum: 0,
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
            lsn: None,
            payload: Some(snapshot_data),
            checksum,
        }
    }

    /// Create a new error message.
    pub fn error(message: String) -> Self {
        Self {
            version: crate::replication::PROTOCOL_VERSION,
            message_type: MessageType::Error,
            sequence: 0,
            commit_record: None,
            lsn: None,
            payload: Some(message.into_bytes()),
            checksum: 0,
        }
    }

    /// Get the message type.
    pub fn message_type(&self) -> MessageType {
        self.message_type
    }

    /// Get the protocol version.
    pub fn version(&self) -> Option<u16> {
        Some(self.version)
    }

    /// Get the sequence number.
    pub fn sequence(&self) -> Option<u64> {
        Some(self.sequence)
    }

    /// Get the LSN if present.
    pub fn lsn(&self) -> Option<u64> {
        self.lsn
    }

    /// Get the payload if present.
    pub fn payload(&self) -> Option<&[u8]> {
        self.payload.as_deref()
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
            MessageType::Heartbeat | MessageType::Snapshot | MessageType::Error |
            MessageType::Connect | MessageType::Accept | MessageType::Ack => true,
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

    /// Serialize this message to bytes in wire format.
    ///
    /// Wire format (little-endian):
    /// - version: u16 (2 bytes)
    /// - message_type: u16 (2 bytes)
    /// - sequence: u64 (8 bytes)
    /// - checksum: u64 (8 bytes)
    /// - payload_length: u32 (4 bytes, 0 if no payload)
    /// - payload: variable (only if payload_length > 0)
    ///
    /// For CommitRecord messages, payload contains the serialized commit record.
    /// For Snapshot messages, payload contains the snapshot data.
    /// For Error messages, payload contains error message bytes.
    /// For Connect/Accept messages, payload may contain LSN info.
    pub fn serialize(&self) -> Result<Vec<u8>, io::Error> {
        let mut buffer = Vec::new();

        // Write header
        buffer.write_u16::<LittleEndian>(self.version)?;
        buffer.write_u16::<LittleEndian>(self.message_type.as_u16())?;
        buffer.write_u64::<LittleEndian>(self.sequence)?;
        buffer.write_u64::<LittleEndian>(self.checksum)?;

        // Write payload based on message type
        let payload_bytes = match self.message_type {
            MessageType::Heartbeat |
            MessageType::Ack |
            MessageType::Connect |
            MessageType::Accept => {
                // No payload needed
                Vec::new()
            }
            MessageType::CommitRecord => {
                // Use pre-serialized payload or serialize the commit record
                if let Some(payload) = &self.payload {
                    payload.clone()
                } else if let Some(record) = &self.commit_record {
                    self.serialize_commit_record(record)?
                } else {
                    Vec::new()
                }
            }
            MessageType::Snapshot => {
                // Snapshot data
                self.payload.clone().unwrap_or_default()
            }
            MessageType::Error => {
                // Error message bytes
                self.payload.clone().unwrap_or_default()
            }
        };

        buffer.write_u32::<LittleEndian>(payload_bytes.len() as u32)?;
        buffer.write_all(&payload_bytes)?;

        Ok(buffer)
    }

    /// Deserialize a message from bytes in wire format.
    pub fn deserialize(data: &[u8]) -> Result<Self, io::Error> {
        let mut cursor = Cursor::new(data);

        // Read header
        let version = cursor.read_u16::<LittleEndian>()?;
        let message_type = cursor.read_u16::<LittleEndian>()?;
        let sequence = cursor.read_u64::<LittleEndian>()?;
        let checksum = cursor.read_u64::<LittleEndian>()?;
        let payload_length = cursor.read_u32::<LittleEndian>()? as usize;

        // Validate message type
        let msg_type = MessageType::from_u16(message_type)
            .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidData, "Invalid message type"))?;

        // Read payload
        let (payload, commit_record) = if payload_length > 0 {
            let mut buf = vec![0u8; payload_length];
            cursor.read_exact(&mut buf)?;

            // Deserialize commit record if this is a CommitRecord message
            if msg_type == MessageType::CommitRecord {
                let record = Self::deserialize_commit_record(&buf)?;
                (None, Some(Box::new(record)))
            } else {
                (Some(buf), None)
            }
        } else {
            (None, None)
        };

        Ok(ReplicationMessage {
            version,
            message_type: msg_type,
            sequence,
            commit_record,
            lsn: None,
            payload,
            checksum,
        })
    }

    /// Serialize a commit record to bytes.
    fn serialize_commit_record(&self, record: &CommitRecord) -> Result<Vec<u8>, io::Error> {
        let mut buffer = Vec::new();

        // Write txn_id (u64)
        buffer.write_u64::<LittleEndian>(record.txn_id.as_u64())?;

        // Write root_page_id (u64)
        buffer.write_u64::<LittleEndian>(record.root_page_id)?;

        // Write checksum (u32)
        buffer.write_u32::<LittleEndian>(record.checksum)?;

        // Write mutation count (u32)
        buffer.write_u32::<LittleEndian>(record.mutations.len() as u32)?;

        // Write each mutation
        for mutation in &record.mutations {
            Self::serialize_mutation(&mut buffer, mutation)?;
        }

        Ok(buffer)
    }

    /// Deserialize a commit record from bytes.
    fn deserialize_commit_record(data: &[u8]) -> Result<CommitRecord, io::Error> {
        let mut cursor = Cursor::new(data);

        // Read txn_id
        let txn_id = TransactionId::new(cursor.read_u64::<LittleEndian>()?);

        // Read root_page_id
        let root_page_id = cursor.read_u64::<LittleEndian>()?;

        // Read checksum
        let checksum = cursor.read_u32::<LittleEndian>()?;

        // Read mutation count
        let mutation_count = cursor.read_u32::<LittleEndian>()? as usize;

        // Read mutations
        let mut mutations = Vec::with_capacity(mutation_count);
        for _ in 0..mutation_count {
            mutations.push(Self::deserialize_mutation(&mut cursor)?);
        }

        Ok(CommitRecord {
            txn_id,
            root_page_id,
            mutations,
            checksum,
        })
    }

    /// Serialize a mutation to bytes.
    fn serialize_mutation<W: Write>(writer: &mut W, mutation: &Mutation) -> Result<(), io::Error> {
        match mutation {
            Mutation::Put { key, value } => {
                // Write variant (0 = Put)
                writer.write_u8(0)?;
                // Write key length and key
                writer.write_u32::<LittleEndian>(key.len() as u32)?;
                writer.write_all(key)?;
                // Write value length and value
                writer.write_u32::<LittleEndian>(value.len() as u32)?;
                writer.write_all(value)?;
            }
            Mutation::Delete { key } => {
                // Write variant (1 = Delete)
                writer.write_u8(1)?;
                // Write key length and key
                writer.write_u32::<LittleEndian>(key.len() as u32)?;
                writer.write_all(key)?;
            }
        }
        Ok(())
    }

    /// Deserialize a mutation from bytes.
    fn deserialize_mutation<R: Read>(reader: &mut R) -> Result<Mutation, io::Error> {
        let variant = reader.read_u8()?;

        match variant {
            0 => {
                // Put
                let key_len = reader.read_u32::<LittleEndian>()? as usize;
                let mut key = vec![0u8; key_len];
                reader.read_exact(&mut key)?;

                let value_len = reader.read_u32::<LittleEndian>()? as usize;
                let mut value = vec![0u8; value_len];
                reader.read_exact(&mut value)?;

                Ok(Mutation::Put { key, value })
            }
            1 => {
                // Delete
                let key_len = reader.read_u32::<LittleEndian>()? as usize;
                let mut key = vec![0u8; key_len];
                reader.read_exact(&mut key)?;

                Ok(Mutation::Delete { key })
            }
            _ => Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "Invalid mutation variant",
            )),
        }
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
        let msg = ReplicationMessage::error("Not found".to_string());

        assert_eq!(msg.version, crate::replication::PROTOCOL_VERSION);
        assert_eq!(msg.message_type, MessageType::Error);
        assert!(msg.is_always_allowed());
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

    #[test]
    fn test_serialize_heartbeat() {
        let msg = ReplicationMessage::heartbeat(123);
        let bytes = msg.serialize().expect("Failed to serialize");

        assert!(!bytes.is_empty());
        assert!(bytes.len() >= 24); // Header size: 2+2+8+8+4 = 24 bytes
    }

    #[test]
    fn test_deserialize_heartbeat() {
        let msg = ReplicationMessage::heartbeat(456);
        let bytes = msg.serialize().expect("Failed to serialize");

        let deserialized = ReplicationMessage::deserialize(&bytes)
            .expect("Failed to deserialize");

        assert_eq!(deserialized.version, msg.version);
        assert_eq!(deserialized.message_type, msg.message_type);
        assert_eq!(deserialized.sequence, msg.sequence);
        assert_eq!(deserialized.checksum, msg.checksum);
    }

    #[test]
    fn test_serialize_commit_record() {
        let txn_id = TransactionId::new(42);
        let mutations = vec![
            Mutation::Put {
                key: b"test_key".to_vec(),
                value: b"test_value".to_vec(),
            },
            Mutation::Delete {
                key: b"delete_key".to_vec(),
            },
        ];
        let record = CommitRecord::new(txn_id, 200, mutations);
        let msg = ReplicationMessage::commit_record(789, record);

        let bytes = msg.serialize().expect("Failed to serialize");

        assert!(!bytes.is_empty());
        assert!(bytes.len() > 24); // Header + payload
    }

    #[test]
    fn test_deserialize_commit_record() {
        let txn_id = TransactionId::new(99);
        let mutations = vec![
            Mutation::Put {
                key: b"key1".to_vec(),
                value: b"value1".to_vec(),
            },
            Mutation::Delete {
                key: b"key2".to_vec(),
            },
        ];
        let record = CommitRecord::new(txn_id, 300, mutations.clone());
        let msg = ReplicationMessage::commit_record(1000, record);

        let bytes = msg.serialize().expect("Failed to serialize");
        let deserialized = ReplicationMessage::deserialize(&bytes)
            .expect("Failed to deserialize");

        assert_eq!(deserialized.version, msg.version);
        assert_eq!(deserialized.message_type, MessageType::CommitRecord);
        assert_eq!(deserialized.sequence, msg.sequence);

        // Verify commit record was preserved
        assert!(deserialized.commit_record.is_some());
        let deserialized_record = deserialized.commit_record.as_ref().unwrap();
        assert_eq!(deserialized_record.txn_id.as_u64(), 99);
        assert_eq!(deserialized_record.root_page_id, 300);
        assert_eq!(deserialized_record.mutations.len(), 2);

        // Verify mutations
        assert_eq!(deserialized_record.mutations[0], mutations[0]);
        assert_eq!(deserialized_record.mutations[1], mutations[1]);

        // Verify checksum
        assert!(deserialized_record.verify());
    }

    #[test]
    fn test_serialize_roundtrip_all_message_types() {
        // Heartbeat
        let heartbeat = ReplicationMessage::heartbeat(1);
        let bytes = heartbeat.serialize().unwrap();
        let deserialized = ReplicationMessage::deserialize(&bytes).unwrap();
        assert_eq!(deserialized.message_type, MessageType::Heartbeat);

        // CommitRecord
        let txn_id = TransactionId::new(1);
        let mutations = vec![
            Mutation::Put {
                key: b"k".to_vec(),
                value: b"v".to_vec(),
            },
        ];
        let record = CommitRecord::new(txn_id, 100, mutations);
        let commit_msg = ReplicationMessage::commit_record(2, record);
        let bytes = commit_msg.serialize().unwrap();
        let deserialized = ReplicationMessage::deserialize(&bytes).unwrap();
        assert_eq!(deserialized.message_type, MessageType::CommitRecord);

        // Snapshot
        let snapshot_msg = ReplicationMessage::snapshot(3, vec![1, 2, 3]);
        let bytes = snapshot_msg.serialize().unwrap();
        let deserialized = ReplicationMessage::deserialize(&bytes).unwrap();
        assert_eq!(deserialized.message_type, MessageType::Snapshot);

        // Error
        let error_msg = ReplicationMessage::error("Internal error".to_string());
        let bytes = error_msg.serialize().unwrap();
        let deserialized = ReplicationMessage::deserialize(&bytes).unwrap();
        assert_eq!(deserialized.message_type, MessageType::Error);
    }

    #[test]
    fn test_deserialize_invalid_message_type() {
        // Create invalid message with unknown type
        let mut bytes = vec![0u8; 24];
        bytes[0] = 1; // version
        bytes[2] = 99; // invalid message type
        bytes[3] = 0;

        let result = ReplicationMessage::deserialize(&bytes);
        assert!(result.is_err());
    }

    #[test]
    fn test_serialize_mutation_put() {
        let mutation = Mutation::Put {
            key: b"test_key".to_vec(),
            value: b"test_value".to_vec(),
        };

        let mut buffer = Vec::new();
        ReplicationMessage::serialize_mutation(&mut buffer, &mutation)
            .expect("Failed to serialize mutation");

        assert!(!buffer.is_empty());

        // Verify structure: variant(1) + key_len(4) + key + value_len(4) + value
        let expected_len = 1 + 4 + b"test_key".len() + 4 + b"test_value".len();
        assert_eq!(buffer.len(), expected_len);
    }

    #[test]
    fn test_deserialize_mutation_put() {
        let mutation = Mutation::Put {
            key: b"my_key".to_vec(),
            value: b"my_value".to_vec(),
        };

        let mut buffer = Vec::new();
        ReplicationMessage::serialize_mutation(&mut buffer, &mutation)
            .expect("Failed to serialize");

        let mut cursor = Cursor::new(buffer.as_slice());
        let deserialized = ReplicationMessage::deserialize_mutation(&mut cursor)
            .expect("Failed to deserialize");

        assert_eq!(deserialized, mutation);
    }

    #[test]
    fn test_serialize_mutation_delete() {
        let mutation = Mutation::Delete {
            key: b"delete_key".to_vec(),
        };

        let mut buffer = Vec::new();
        ReplicationMessage::serialize_mutation(&mut buffer, &mutation)
            .expect("Failed to serialize mutation");

        assert!(!buffer.is_empty());

        // Verify structure: variant(1) + key_len(4) + key
        let expected_len = 1 + 4 + b"delete_key".len();
        assert_eq!(buffer.len(), expected_len);
    }

    #[test]
    fn test_deserialize_mutation_delete() {
        let mutation = Mutation::Delete {
            key: b"del_key".to_vec(),
        };

        let mut buffer = Vec::new();
        ReplicationMessage::serialize_mutation(&mut buffer, &mutation)
            .expect("Failed to serialize");

        let mut cursor = Cursor::new(buffer.as_slice());
        let deserialized = ReplicationMessage::deserialize_mutation(&mut cursor)
            .expect("Failed to deserialize");

        assert_eq!(deserialized, mutation);
    }

    #[test]
    fn test_deserialize_invalid_mutation_variant() {
        let bytes = vec![255u8]; // Invalid variant
        let mut cursor = Cursor::new(bytes.as_slice());

        let result = ReplicationMessage::deserialize_mutation(&mut cursor);
        assert!(result.is_err());
    }

    #[test]
    fn test_serialize_large_commit_record() {
        // Test with many mutations to ensure it handles larger payloads
        let txn_id = TransactionId::new(1);
        let mutations: Vec<Mutation> = (0..100)
            .map(|i| Mutation::Put {
                key: format!("key_{}", i).into_bytes(),
                value: format!("value_{}", i).into_bytes(),
            })
            .collect();

        let record = CommitRecord::new(txn_id, 100, mutations);
        let msg = ReplicationMessage::commit_record(1, record);

        let bytes = msg.serialize().expect("Failed to serialize large record");
        assert!(bytes.len() > 1000); // Should be substantial

        let deserialized = ReplicationMessage::deserialize(&bytes)
            .expect("Failed to deserialize large record");

        assert!(deserialized.commit_record.is_some());
        let deserialized_record = deserialized.commit_record.as_ref().unwrap();
        assert_eq!(deserialized_record.mutations.len(), 100);
        assert!(deserialized_record.verify());
    }
}
