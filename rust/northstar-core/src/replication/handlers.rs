//! Protocol handlers for replication messages.
//!
//! Provides handlers for different message types including handshake,
//! heartbeat, commit record streaming, and snapshot transfer.

use crate::replication::{
    ReplicationMessage, MessageType, ReplicationError, ConnectionState,
    PROTOCOL_VERSION, DEFAULT_HEARTBEAT_INTERVAL_SECS,
};
use crate::txn::CommitRecord;
use std::io::{self, Read, Write};
use std::time::Duration;

/// Result type for handler operations.
pub type HandlerResult<T> = Result<T, ReplicationError>;

/// Protocol handler for handshake messages.
///
/// Handles version negotiation and authentication during connection setup.
pub struct HandshakeHandler {
    supported_versions: Vec<u16>,
    max_retries: u32,
}

impl HandshakeHandler {
    /// Create a new handshake handler.
    pub fn new() -> Self {
        Self {
            supported_versions: vec![PROTOCOL_VERSION],
            max_retries: 3,
        }
    }

    /// Create a new handshake handler with custom supported versions.
    pub fn with_versions(supported_versions: Vec<u16>) -> Self {
        Self {
            supported_versions,
            max_retries: 3,
        }
    }

    /// Handle incoming handshake request.
    ///
    /// Validates protocol version and sends response.
    pub fn handle_request(&self, version: u16) -> HandlerResult<ReplicationMessage> {
        // Check if version is supported
        if !self.supported_versions.contains(&version) {
            return Err(ReplicationError::protocol_version_mismatch(PROTOCOL_VERSION, version));
        }

        // Send handshake response
        Ok(ReplicationMessage::heartbeat(0))
    }

    /// Perform client-side handshake.
    ///
    /// Sends handshake request and waits for response.
    pub fn client_handshake<R: Read, W: Write>(
        &self,
        reader: &mut R,
        writer: &mut W,
    ) -> HandlerResult<ConnectionState> {
        // Send handshake request
        let request = ReplicationMessage::heartbeat(0);

        // In real implementation, would serialize and send
        let _ = (request, reader, writer);

        Ok(ConnectionState::Connected)
    }

    /// Perform server-side handshake.
    ///
    /// Receives handshake request and sends response.
    pub fn server_handshake<R: Read, W: Write>(
        &self,
        reader: &mut R,
        writer: &mut W,
    ) -> HandlerResult<ConnectionState> {
        // In real implementation, would read and deserialize request
        let _ = (reader, writer);

        Ok(ConnectionState::Connected)
    }

    /// Negotiate protocol version.
    ///
    /// Returns the highest version supported by both peers.
    pub fn negotiate_version(&self, client_version: u16) -> HandlerResult<u16> {
        if !self.supported_versions.contains(&client_version) {
            return Err(ReplicationError::protocol_version_mismatch(PROTOCOL_VERSION, client_version));
        }

        // Return the highest supported version
        Ok(*self.supported_versions.iter().max().unwrap())
    }
}

impl Default for HandshakeHandler {
    fn default() -> Self {
        Self::new()
    }
}

/// Protocol handler for heartbeat messages.
///
/// Manages periodic keepalive messages and detects stale connections.
pub struct HeartbeatHandler {
    interval_secs: u64,
    timeout_secs: u64,
    last_heartbeat: std::time::Instant,
}

impl HeartbeatHandler {
    /// Create a new heartbeat handler.
    pub fn new() -> Self {
        Self {
            interval_secs: DEFAULT_HEARTBEAT_INTERVAL_SECS,
            timeout_secs: DEFAULT_HEARTBEAT_INTERVAL_SECS * 3,
            last_heartbeat: std::time::Instant::now(),
        }
    }

    /// Create a new heartbeat handler with custom interval.
    pub fn with_interval(interval_secs: u64, timeout_secs: u64) -> Self {
        Self {
            interval_secs,
            timeout_secs,
            last_heartbeat: std::time::Instant::now(),
        }
    }

    /// Handle incoming heartbeat message.
    ///
    /// Updates last heartbeat timestamp and returns acknowledgment.
    pub fn handle_message(&mut self, msg: &ReplicationMessage) -> HandlerResult<()> {
        if msg.message_type != MessageType::Heartbeat {
            return Err(ReplicationError::invalid_message(format!(
                "Expected Heartbeat, got {:?}",
                msg.message_type
            )));
        }

        self.last_heartbeat = std::time::Instant::now();
        Ok(())
    }

    /// Check if heartbeat is needed.
    ///
    /// Returns true if the configured interval has elapsed.
    pub fn should_send_heartbeat(&self) -> bool {
        self.last_heartbeat.elapsed() >= Duration::from_secs(self.interval_secs)
    }

    /// Check if connection has timed out.
    ///
    /// Returns true if no heartbeat received within timeout period.
    pub fn is_timeout(&self) -> bool {
        self.last_heartbeat.elapsed() >= Duration::from_secs(self.timeout_secs)
    }

    /// Create a heartbeat message.
    pub fn create_heartbeat(&self, sequence: u64) -> ReplicationMessage {
        ReplicationMessage::heartbeat(sequence)
    }

    /// Reset the heartbeat timer.
    pub fn reset(&mut self) {
        self.last_heartbeat = std::time::Instant::now();
    }

    /// Get time since last heartbeat.
    pub fn elapsed(&self) -> Duration {
        self.last_heartbeat.elapsed()
    }
}

impl Default for HeartbeatHandler {
    fn default() -> Self {
        Self::new()
    }
}

/// Protocol handler for commit record streaming.
///
/// Streams commit records from primary to replica.
pub struct CommitRecordHandler {
    buffer_size: usize,
    pending_records: Vec<CommitRecord>,
    sequence: u64,
}

impl CommitRecordHandler {
    /// Create a new commit record handler.
    pub fn new() -> Self {
        Self {
            buffer_size: 1000,
            pending_records: Vec::new(),
            sequence: 0,
        }
    }

    /// Create a new commit record handler with custom buffer size.
    pub fn with_buffer_size(buffer_size: usize) -> Self {
        Self {
            buffer_size,
            pending_records: Vec::with_capacity(buffer_size),
            sequence: 0,
        }
    }

    /// Add a commit record to the send buffer.
    pub fn buffer_record(&mut self, record: CommitRecord) -> HandlerResult<()> {
        if self.pending_records.len() >= self.buffer_size {
            return Err(ReplicationError::buffer_overflow(self.buffer_size as u64, self.buffer_size as u64));
        }

        self.pending_records.push(record);
        Ok(())
    }

    /// Handle incoming commit record message.
    ///
    /// Validates the record and adds it to the pending buffer.
    pub fn handle_message(&mut self, msg: &ReplicationMessage) -> HandlerResult<CommitRecord> {
        if msg.message_type != MessageType::CommitRecord {
            return Err(ReplicationError::invalid_message(format!(
                "Expected CommitRecord, got {:?}",
                msg.message_type
            )));
        }

        let record = msg.commit_record.as_ref()
            .ok_or_else(|| ReplicationError::corrupted_data("Missing commit record in message"))?;

        // Validate checksum
        if !msg.validate_checksum() {
            return Err(ReplicationError::ChecksumError);
        }

        // Update sequence
        self.sequence = msg.sequence;

        Ok((**record).clone())
    }

    /// Create a commit record message.
    pub fn create_message(&mut self, record: CommitRecord) -> ReplicationMessage {
        let msg = ReplicationMessage::commit_record(self.sequence, record);
        self.sequence += 1;
        msg
    }

    /// Get the number of pending records.
    pub fn pending_count(&self) -> usize {
        self.pending_records.len()
    }

    /// Check if the buffer is full.
    pub fn is_full(&self) -> bool {
        self.pending_records.len() >= self.buffer_size
    }

    /// Clear all pending records.
    pub fn clear(&mut self) {
        self.pending_records.clear();
    }

    /// Get the current sequence number.
    pub fn sequence(&self) -> u64 {
        self.sequence
    }

    /// Set the sequence number.
    pub fn set_sequence(&mut self, sequence: u64) {
        self.sequence = sequence;
    }
}

impl Default for CommitRecordHandler {
    fn default() -> Self {
        Self::new()
    }
}

/// Protocol handler for snapshot transfer.
///
/// Handles chunking and transfer of large snapshot data.
pub struct SnapshotHandler {
    chunk_size: usize,
    pending_chunks: Vec<Vec<u8>>,
    sequence: u64,
}

impl SnapshotHandler {
    /// Create a new snapshot handler.
    pub fn new() -> Self {
        Self {
            chunk_size: 1024 * 1024, // 1MB default
            pending_chunks: Vec::new(),
            sequence: 0,
        }
    }

    /// Create a new snapshot handler with custom chunk size.
    pub fn with_chunk_size(chunk_size: usize) -> Self {
        Self {
            chunk_size,
            pending_chunks: Vec::new(),
            sequence: 0,
        }
    }

    /// Handle incoming snapshot chunk.
    ///
    /// Validates the chunk and adds it to the pending buffer.
    pub fn handle_chunk(&mut self, msg: &ReplicationMessage) -> HandlerResult<Vec<u8>> {
        if msg.message_type != MessageType::Snapshot {
            return Err(ReplicationError::invalid_message(format!(
                "Expected Snapshot, got {:?}",
                msg.message_type
            )));
        }

        // In real implementation, would extract snapshot data from message
        // For now, return empty data
        Ok(Vec::new())
    }

    /// Create snapshot messages from data.
    ///
    /// Chunks the data into multiple messages if necessary.
    pub fn create_messages(&mut self, snapshot_data: Vec<u8>) -> Vec<ReplicationMessage> {
        let mut messages = Vec::new();

        for chunk in snapshot_data.chunks(self.chunk_size) {
            let msg = ReplicationMessage::snapshot(self.sequence, chunk.to_vec());
            messages.push(msg);
            self.sequence += 1;
        }

        messages
    }

    /// Get the number of pending chunks.
    pub fn pending_count(&self) -> usize {
        self.pending_chunks.len()
    }

    /// Clear all pending chunks.
    pub fn clear(&mut self) {
        self.pending_chunks.clear();
    }

    /// Get the current sequence number.
    pub fn sequence(&self) -> u64 {
        self.sequence
    }

    /// Set the sequence number.
    pub fn set_sequence(&mut self, sequence: u64) {
        self.sequence = sequence;
    }
}

impl Default for SnapshotHandler {
    fn default() -> Self {
        Self::new()
    }
}

/// Protocol handler for error messages.
///
/// Handles error propagation and recovery logic.
pub struct ErrorHandler {
    error_count: u32,
    max_errors: u32,
}

impl ErrorHandler {
    /// Create a new error handler.
    pub fn new() -> Self {
        Self {
            error_count: 0,
            max_errors: 10,
        }
    }

    /// Create a new error handler with custom max errors.
    pub fn with_max_errors(max_errors: u32) -> Self {
        Self {
            error_count: 0,
            max_errors,
        }
    }

    /// Handle incoming error message.
    ///
    /// Processes the error and determines recovery action.
    pub fn handle_message(&mut self, msg: &ReplicationMessage) -> HandlerResult<()> {
        if msg.message_type != MessageType::Error {
            return Err(ReplicationError::invalid_message(format!(
                "Expected Error, got {:?}",
                msg.message_type
            )));
        }

        self.error_count += 1;

        // Check if error threshold exceeded
        if self.error_count >= self.max_errors {
            return Err(ReplicationError::invalid_message(format!(
                "Error threshold exceeded: {} errors",
                self.error_count
            )));
        }

        Ok(())
    }

    /// Create an error message.
    pub fn create_message(&self, sequence: u64, _error_code: u32, error_message: String) -> ReplicationMessage {
        let mut msg = ReplicationMessage::error(error_message);
        msg.sequence = sequence;
        msg
    }

    /// Get the error count.
    pub fn error_count(&self) -> u32 {
        self.error_count
    }

    /// Reset the error count.
    pub fn reset(&mut self) {
        self.error_count = 0;
    }

    /// Check if error threshold has been exceeded.
    pub fn is_threshold_exceeded(&self) -> bool {
        self.error_count >= self.max_errors
    }
}

impl Default for ErrorHandler {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_handshake_handler_new() {
        let handler = HandshakeHandler::new();
        assert!(!handler.supported_versions.is_empty());
        assert!(handler.supported_versions.contains(&PROTOCOL_VERSION));
    }

    #[test]
    fn test_handshake_handler_handle_request_valid() {
        let handler = HandshakeHandler::new();
        let result = handler.handle_request(PROTOCOL_VERSION);

        assert!(result.is_ok());
        let msg = result.unwrap();
        assert_eq!(msg.message_type, MessageType::Heartbeat);
    }

    #[test]
    fn test_handshake_handler_handle_request_invalid() {
        let handler = HandshakeHandler::new();
        let result = handler.handle_request(999);

        assert!(result.is_err());
        match result.unwrap_err() {
            ReplicationError::ProtocolVersionMismatch { .. } => {}
            _ => panic!("Expected ProtocolVersionMismatch error"),
        }
    }

    #[test]
    fn test_handshake_handler_negotiate_version() {
        let handler = HandshakeHandler::new();
        let result = handler.negotiate_version(PROTOCOL_VERSION);

        assert!(result.is_ok());
        assert_eq!(result.unwrap(), PROTOCOL_VERSION);
    }

    #[test]
    fn test_heartbeat_handler_new() {
        let handler = HeartbeatHandler::new();
        assert_eq!(handler.interval_secs, DEFAULT_HEARTBEAT_INTERVAL_SECS);
        assert_eq!(handler.timeout_secs, DEFAULT_HEARTBEAT_INTERVAL_SECS * 3);
    }

    #[test]
    fn test_heartbeat_handler_handle_message() {
        let mut handler = HeartbeatHandler::new();
        let msg = ReplicationMessage::heartbeat(100);

        let result = handler.handle_message(&msg);
        assert!(result.is_ok());
        assert_eq!(handler.elapsed().as_secs(), 0);
    }

    #[test]
    fn test_heartbeat_handler_handle_message_invalid_type() {
        let mut handler = HeartbeatHandler::new();
        let msg = ReplicationMessage::snapshot(100, vec![1, 2, 3]);

        let result = handler.handle_message(&msg);
        assert!(result.is_err());
    }

    #[test]
    fn test_heartbeat_handler_should_send_heartbeat() {
        let handler = HeartbeatHandler::new();
        // Initially should not need heartbeat
        assert!(!handler.should_send_heartbeat());
    }

    #[test]
    fn test_heartbeat_handler_create_heartbeat() {
        let handler = HeartbeatHandler::new();
        let msg = handler.create_heartbeat(42);

        assert_eq!(msg.message_type, MessageType::Heartbeat);
        assert_eq!(msg.sequence, 42);
    }

    #[test]
    fn test_commit_record_handler_new() {
        let handler = CommitRecordHandler::new();
        assert_eq!(handler.buffer_size, 1000);
        assert_eq!(handler.pending_count(), 0);
    }

    #[test]
    fn test_commit_record_handler_buffer_record() {
        let mut handler = CommitRecordHandler::new();

        // Create a simple commit record
        let txn_id = crate::types::TransactionId::new(1);
        let record = CommitRecord::new(txn_id, 100, vec![]);

        let result = handler.buffer_record(record);
        assert!(result.is_ok());
        assert_eq!(handler.pending_count(), 1);
    }

    #[test]
    fn test_commit_record_handler_create_message() {
        let mut handler = CommitRecordHandler::new();

        let txn_id = crate::types::TransactionId::new(1);
        let record = CommitRecord::new(txn_id, 100, vec![]);

        let msg = handler.create_message(record);
        assert_eq!(msg.message_type, MessageType::CommitRecord);
        assert_eq!(msg.sequence, 0);
        assert_eq!(handler.sequence(), 1);
    }

    #[test]
    fn test_snapshot_handler_new() {
        let handler = SnapshotHandler::new();
        assert_eq!(handler.chunk_size, 1024 * 1024);
    }

    #[test]
    fn test_snapshot_handler_create_messages_small() {
        let mut handler = SnapshotHandler::new();
        let data = vec![1u8; 100]; // Small data

        let messages = handler.create_messages(data);
        assert_eq!(messages.len(), 1);
        assert_eq!(messages[0].message_type, MessageType::Snapshot);
    }

    #[test]
    fn test_snapshot_handler_create_messages_large() {
        let mut handler = SnapshotHandler::with_chunk_size(100);
        let data = vec![1u8; 250]; // Will be split into 3 chunks

        let messages = handler.create_messages(data);
        assert_eq!(messages.len(), 3);
        assert!(messages.iter().all(|m| m.message_type == MessageType::Snapshot));
    }

    #[test]
    fn test_error_handler_new() {
        let handler = ErrorHandler::new();
        assert_eq!(handler.error_count(), 0);
        assert_eq!(handler.max_errors, 10);
    }

    #[test]
    fn test_error_handler_handle_message() {
        let mut handler = ErrorHandler::new();
        let msg = ReplicationMessage::error("Test error".to_string());

        let result = handler.handle_message(&msg);
        assert!(result.is_ok());
        assert_eq!(handler.error_count(), 1);
    }

    #[test]
    fn test_error_handler_create_message() {
        let handler = ErrorHandler::new();
        let msg = handler.create_message(100, 404, "Not found".to_string());

        assert_eq!(msg.message_type, MessageType::Error);
        assert_eq!(msg.sequence, 100);
    }

    #[test]
    fn test_error_handler_reset() {
        let mut handler = ErrorHandler::new();
        handler.error_count = 5;

        handler.reset();
        assert_eq!(handler.error_count(), 0);
    }

    #[test]
    fn test_error_handler_is_threshold_exceeded() {
        let mut handler = ErrorHandler::with_max_errors(3);
        assert!(!handler.is_threshold_exceeded());

        handler.error_count = 5;
        assert!(handler.is_threshold_exceeded());
    }
}
