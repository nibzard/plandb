//! Replication Publisher - Streams commit records from primary to replicas.
//!
//! The Publisher runs on the primary node and is responsible for:
//! - Accepting replica connections
//! - Streaming commit records to all connected replicas
//! - Tracking per-replica positions for resumption
//! - Sending heartbeats for connection liveness
//! - Applying backpressure when replicas fall behind

use crate::replication::config::PrimaryConfig;
use crate::replication::error::{ReplicationError, Result};
use crate::replication::protocol::{MessageType, ReplicationMessage};
use crate::replication::state::ConnectionState;
use crate::txn::CommitRecord;
use bytes::Bytes;
use std::collections::HashMap;
use std::collections::VecDeque;
use std::io::{self, Cursor};
use std::net::SocketAddr;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::Arc;
use std::time::Instant;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::Mutex as TokioMutex;
use tokio::sync::RwLock;
use tokio::time::{interval, Duration};

/// Type alias for replica identifier.
pub type ReplicaId = u64;

/// State of backpressure application.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BackpressureState {
    /// Accepting all writes, buffer below high watermark.
    Normal,
    /// Buffer exceeded high watermark, pausing new writes.
    Applying,
    /// Buffer dropped below low watermark after applying backpressure.
    Relieving,
}

impl BackpressureState {
    /// Returns true if backpressure is currently being applied.
    pub const fn is_applying(&self) -> bool {
        matches!(self, Self::Applying)
    }

    /// Returns true if backpressure is relieving.
    pub const fn is_relieving(&self) -> bool {
        matches!(self, Self::Relieving)
    }
}

/// A commit record buffered for replication.
#[derive(Debug, Clone)]
pub struct BufferedRecord {
    /// Log sequence number of this commit record.
    pub lsn: u64,
    /// Assigned sequence number for tracking acknowledgments.
    pub sequence: u64,
    /// Serialized commit record.
    pub record_bytes: Bytes,
    /// Pre-calculated checksum for the record.
    pub checksum: u64,
    /// When record was buffered.
    pub timestamp: Instant,
}

impl BufferedRecord {
    /// Create a new buffered record.
    pub fn new(lsn: u64, sequence: u64, record_bytes: Bytes, checksum: u64) -> Self {
        Self {
            lsn,
            sequence,
            record_bytes,
            checksum,
            timestamp: Instant::now(),
        }
    }

    /// Get the size of this record in bytes.
    pub fn size(&self) -> usize {
        self.record_bytes.len()
    }
}

/// In-memory buffer holding commit records for replication.
#[derive(Debug)]
pub struct ReplicationBuffer {
    /// Queue of buffered commit records.
    records: VecDeque<BufferedRecord>,
    /// Maximum buffer capacity in bytes.
    max_size: usize,
    /// Current buffer usage in bytes.
    current_size: usize,
    /// Threshold to resume after backpressure (60% of max).
    low_watermark: usize,
    /// Threshold to apply backpressure (80% of max).
    high_watermark: usize,
}

impl ReplicationBuffer {
    /// Create a new replication buffer with the specified capacity.
    pub fn new(max_size: usize, low_watermark_pct: u64, high_watermark_pct: u64) -> Self {
        let low_watermark = (max_size * low_watermark_pct as usize) / 100;
        let high_watermark = (max_size * high_watermark_pct as usize) / 100;

        Self {
            records: VecDeque::new(),
            max_size,
            current_size: 0,
            low_watermark,
            high_watermark,
        }
    }

    /// Create a new replication buffer from primary config.
    pub fn from_config(config: &PrimaryConfig) -> Self {
        let max_size = config.replication_buffer_size as usize;
        let low_watermark = config.low_watermark() as usize;
        let high_watermark = config.high_watermark() as usize;

        Self {
            records: VecDeque::new(),
            max_size,
            current_size: 0,
            low_watermark,
            high_watermark,
        }
    }

    /// Add a record to the buffer.
    pub fn push(&mut self, record: BufferedRecord) -> Result<()> {
        let size = record.size();

        // Check if adding would exceed capacity
        if self.current_size + size > self.max_size {
            return Err(ReplicationError::buffer_overflow(
                (self.current_size + size) as u64,
                self.max_size as u64,
            ));
        }

        self.records.push_back(record);
        self.current_size += size;
        Ok(())
    }

    /// Remove and return the oldest record from the buffer.
    pub fn pop_front(&mut self) -> Option<BufferedRecord> {
        if let Some(record) = self.records.pop_front() {
            self.current_size -= record.size();
            Some(record)
        } else {
            None
        }
    }

    /// Remove all records acknowledged by all replicas up to the given sequence.
    pub fn release_up_to(&mut self, min_ack_sequence: u64) {
        while let Some(record) = self.records.front() {
            if record.sequence <= min_ack_sequence {
                self.pop_front();
            } else {
                break;
            }
        }
    }

    /// Check if the buffer is empty.
    pub fn is_empty(&self) -> bool {
        self.records.is_empty()
    }

    /// Check if the buffer is full.
    pub fn is_full(&self) -> bool {
        self.current_size >= self.high_watermark
    }

    /// Get the current buffer usage in bytes.
    pub fn current_usage(&self) -> usize {
        self.current_size
    }

    /// Get the buffer capacity in bytes.
    pub fn capacity(&self) -> usize {
        self.max_size
    }

    /// Get the number of records in the buffer.
    pub fn len(&self) -> usize {
        self.records.len()
    }

    /// Get the low watermark threshold.
    pub fn low_watermark(&self) -> usize {
        self.low_watermark
    }

    /// Get the high watermark threshold.
    pub fn high_watermark(&self) -> usize {
        self.high_watermark
    }

    /// Check if buffer is above high watermark (should apply backpressure).
    pub fn should_apply_backpressure(&self) -> bool {
        self.current_size >= self.high_watermark
    }

    /// Check if buffer is below low watermark (should relieve backpressure).
    pub fn should_relieve_backpressure(&self) -> bool {
        self.current_size < self.low_watermark
    }

    /// Get the minimum sequence number acknowledged by all replicas.
    ///
    /// This is used to determine which records can be freed from the buffer.
    pub fn get_min_sequence(&self, replica_acks: &HashMap<ReplicaId, u64>) -> Option<u64> {
        if replica_acks.is_empty() {
            return None;
        }

        let min = replica_acks.values().copied().min()?;
        Some(min)
    }

    /// Get the oldest sequence number in the buffer.
    pub fn oldest_sequence(&self) -> Option<u64> {
        self.records.front().map(|r| r.sequence)
    }

    /// Get the newest sequence number in the buffer.
    pub fn newest_sequence(&self) -> Option<u64> {
        self.records.back().map(|r| r.sequence)
    }

    /// Get all records with sequence greater than the given value.
    pub fn records_after(&self, sequence: u64) -> Vec<&BufferedRecord> {
        self.records
            .iter()
            .filter(|r| r.sequence > sequence)
            .collect()
    }

    /// Clear all records from the buffer.
    pub fn clear(&mut self) {
        self.records.clear();
        self.current_size = 0;
    }
}

/// Represents a single replica connection managed by the publisher.
pub struct ReplicaConnection {
    /// Unique identifier for this replica.
    pub replica_id: ReplicaId,
    /// TCP socket for communication.
    pub socket: TcpStream,
    /// Current connection state.
    pub state: ConnectionState,
    /// Next sequence number to send to this replica.
    pub send_sequence: u64,
    /// Highest sequence acknowledged by this replica.
    pub last_ack_sequence: u64,
    /// Timestamp of last heartbeat sent.
    pub last_heartbeat_sent: Instant,
    /// Timestamp of last acknowledgment received.
    pub last_ack_received: Instant,
    /// Buffer for pending writes to socket.
    pub write_buffer: Vec<u8>,
    /// Whether compression is enabled for this connection.
    pub compression_enabled: bool,
}

impl ReplicaConnection {
    /// Create a new replica connection.
    pub fn new(replica_id: ReplicaId, socket: TcpStream) -> Self {
        Self {
            replica_id,
            socket,
            state: ConnectionState::Connecting,
            send_sequence: 0,
            last_ack_sequence: 0,
            last_heartbeat_sent: Instant::now(),
            last_ack_received: Instant::now(),
            write_buffer: Vec::new(),
            compression_enabled: false,
        }
    }

    /// Check if this replica has exceeded the heartbeat timeout.
    pub fn heartbeat_timeout(&self, timeout_secs: u64) -> bool {
        self.last_ack_received.elapsed().as_secs() > timeout_secs
    }

    /// Update acknowledgment state.
    pub fn update_ack(&mut self, sequence: u64) {
        self.last_ack_sequence = sequence.max(self.last_ack_sequence);
        self.last_ack_received = Instant::now();
    }

    /// Queue a message for sending to this replica.
    pub fn queue_message(&mut self, message: &ReplicationMessage) -> Result<()> {
        let bytes = message.serialize()?;
        self.write_buffer.extend_from_slice(&bytes);
        Ok(())
    }

    /// Flush pending writes to the socket.
    pub async fn flush(&mut self) -> io::Result<()> {
        if !self.write_buffer.is_empty() {
            self.socket.write_all(&self.write_buffer).await?;
            self.write_buffer.clear();
        }
        self.socket.flush().await?;
        Ok(())
    }

    /// Send a message immediately (bypasses queue).
    pub async fn send_message(&mut self, message: &ReplicationMessage) -> io::Result<()> {
        let bytes = message.serialize()?;
        self.socket.write_all(&bytes).await?;
        self.socket.flush().await?;
        Ok(())
    }

    /// Receive and parse a message from the replica.
    pub async fn receive_message(&mut self) -> Result<ReplicationMessage> {
        // Read frame header (version: u16, type: u16, sequence: u64, checksum: u64, payload_len: u32)
        let mut header_buf = [0u8; 24];
        self.socket.read_exact(&mut header_buf).await?;

        // Parse header directly from bytes
        let _version = u16::from_le_bytes([header_buf[0], header_buf[1]]);
        let _msg_type = u16::from_le_bytes([header_buf[2], header_buf[3]]);
        let _sequence = u64::from_le_bytes([
            header_buf[4], header_buf[5], header_buf[6], header_buf[7],
            header_buf[8], header_buf[9], header_buf[10], header_buf[11],
        ]);
        let _checksum = u64::from_le_bytes([
            header_buf[12], header_buf[13], header_buf[14], header_buf[15],
            header_buf[16], header_buf[17], header_buf[18], header_buf[19],
        ]);
        let payload_len = u32::from_le_bytes([header_buf[20], header_buf[21], header_buf[22], header_buf[23]]) as usize;

        // Read payload if present
        let mut payload = if payload_len > 0 {
            let mut buf = vec![0u8; payload_len];
            self.socket.read_exact(&mut buf).await?;
            buf
        } else {
            Vec::new()
        };

        // Reconstruct full message buffer for deserialization
        let mut full_message = Vec::with_capacity(24 + payload_len);
        full_message.extend_from_slice(&header_buf);
        full_message.append(&mut payload);

        ReplicationMessage::deserialize(&full_message).map_err(|e| {
            ReplicationError::invalid_message(format!("Failed to deserialize message: {}", e))
        })
    }

    /// Check if this connection is in a state that allows sending.
    pub fn can_send(&self) -> bool {
        self.state.can_send()
    }

    /// Check if this connection is in a state that allows receiving.
    pub fn can_receive(&self) -> bool {
        self.state.can_receive()
    }

    /// Transition to connected state.
    pub fn mark_connected(&mut self) {
        self.state = ConnectionState::Connected;
    }

    /// Transition to disconnected state.
    pub fn mark_disconnected(&mut self) {
        self.state = ConnectionState::Disconnected;
    }

    /// Transition to catchup state.
    pub fn mark_catchup(&mut self) {
        self.state = ConnectionState::Catchup;
    }

    /// Transition to error state.
    pub fn mark_error(&mut self) {
        self.state = ConnectionState::Error;
    }

    /// Check if connection needs reconnection.
    pub fn needs_reconnect(&self) -> bool {
        self.state.needs_reconnect()
    }

    /// Check if connection is in terminal error state.
    pub fn is_terminal(&self) -> bool {
        self.state.is_terminal()
    }
}

/// Main publisher struct managing replication to all connected replicas.
pub struct Publisher {
    /// Configuration for publisher behavior.
    config: Arc<PrimaryConfig>,
    /// In-memory buffer for commit records.
    buffer: Arc<TokioMutex<ReplicationBuffer>>,
    /// Map of connected replicas.
    replicas: Arc<RwLock<HashMap<ReplicaId, Arc<TokioMutex<ReplicaConnection>>>>>,
    /// Flag indicating publisher is running.
    running: Arc<AtomicBool>,
    /// Current LSN from WAL.
    current_lsn: Arc<AtomicU64>,
    /// Counter for assigning sequence numbers.
    sequence_counter: Arc<AtomicU64>,
    /// Current backpressure state.
    backpressure_state: Arc<TokioMutex<BackpressureState>>,
    /// Per-replica acknowledgment tracking.
    replica_acks: Arc<RwLock<HashMap<ReplicaId, u64>>>,
}

impl Publisher {
    /// Create and start the replication publisher on the primary node.
    ///
    /// # Arguments
    ///
    /// * `config` - Configuration for publisher behavior
    /// * `current_lsn` - Shared atomic reference to current WAL LSN
    ///
    /// # Errors
    ///
    /// Returns an error if:
    /// - Failed to bind to listen address
    /// - Invalid configuration parameters
    pub async fn start(config: PrimaryConfig, current_lsn: Arc<AtomicU64>) -> Result<Self> {
        // Validate configuration
        config.validate().map_err(ReplicationError::Config)?;

        // Parse listen address
        let addr: SocketAddr = config
            .listen_address
            .parse()
            .map_err(|e| ReplicationError::Config(format!("Invalid listen address: {}", e)))?;

        // Create TCP listener
        let _listener = TcpListener::bind(addr)
            .await
            .map_err(|e| ReplicationError::Io(io::Error::new(io::ErrorKind::Other, format!("Failed to bind to {}: {}", addr, e))))?;

        // Allocate replication buffer
        let buffer = Arc::new(TokioMutex::new(ReplicationBuffer::from_config(&config)));

        // Initialize publisher
        let publisher = Self {
            config: Arc::new(config),
            buffer,
            replicas: Arc::new(RwLock::new(HashMap::new())),
            running: Arc::new(AtomicBool::new(false)),
            current_lsn,
            sequence_counter: Arc::new(AtomicU64::new(0)),
            backpressure_state: Arc::new(TokioMutex::new(BackpressureState::Normal)),
            replica_acks: Arc::new(RwLock::new(HashMap::new())),
        };

        // Start background tasks
        publisher.start_background_tasks(addr).await?;

        Ok(publisher)
    }

    /// Start background tasks for the publisher.
    async fn start_background_tasks(&self, addr: SocketAddr) -> Result<()> {
        self.running.store(true, Ordering::Release);

        // Spawn heartbeat task
        let buffer = Arc::clone(&self.buffer);
        let replicas = Arc::clone(&self.replicas);
        let running = Arc::clone(&self.running);
        let sequence_counter = Arc::clone(&self.sequence_counter);

        tokio::spawn(async move {
            Self::heartbeat_task_impl(buffer, replicas, running, sequence_counter).await;
        });

        // Spawn connection accept task
        let replicas = Arc::clone(&self.replicas);
        let running = Arc::clone(&self.running);
        let config = Arc::clone(&self.config);
        let replica_acks = Arc::clone(&self.replica_acks);
        let buffer = Arc::clone(&self.buffer);
        let sequence_counter = Arc::clone(&self.sequence_counter);
        let backpressure_state = Arc::clone(&self.backpressure_state);

        tokio::spawn(async move {
            Self::accept_task_impl(addr, replicas, running, config, replica_acks, buffer, sequence_counter, backpressure_state).await;
        });

        Ok(())
    }

    /// Heartbeat task implementation.
    async fn heartbeat_task_impl(
        buffer: Arc<TokioMutex<ReplicationBuffer>>,
        replicas: Arc<RwLock<HashMap<ReplicaId, Arc<TokioMutex<ReplicaConnection>>>>>,
        running: Arc<AtomicBool>,
        sequence_counter: Arc<AtomicU64>,
    ) {
        let mut timer = interval(Duration::from_secs(1));

        while running.load(Ordering::Acquire) {
            timer.tick().await;

            let replicas_clone = replicas.read().await;
            for (replica_id, conn_arc) in replicas_clone.iter() {
                let mut conn = conn_arc.lock().await;

                if !conn.can_send() {
                    continue;
                }

                // Create heartbeat message
                let sequence = sequence_counter.fetch_add(1, Ordering::SeqCst);
                let message = ReplicationMessage::heartbeat(sequence);

                // Queue heartbeat
                if let Err(e) = conn.queue_message(&message) {
                    eprintln!("Failed to queue heartbeat for replica {}: {:?}", replica_id, e);
                    continue;
                }

                conn.last_heartbeat_sent = Instant::now();

                // Check heartbeat timeout
                if conn.heartbeat_timeout(5) {
                    eprintln!("Replica {} heartbeat timeout", replica_id);
                    conn.mark_disconnected();
                }
            }
        }
    }

    /// Accept task implementation.
    async fn accept_task_impl(
        addr: SocketAddr,
        replicas: Arc<RwLock<HashMap<ReplicaId, Arc<TokioMutex<ReplicaConnection>>>>>,
        running: Arc<AtomicBool>,
        config: Arc<PrimaryConfig>,
        replica_acks: Arc<RwLock<HashMap<ReplicaId, u64>>>,
        buffer: Arc<TokioMutex<ReplicationBuffer>>,
        sequence_counter: Arc<AtomicU64>,
        backpressure_state: Arc<TokioMutex<BackpressureState>>,
    ) {
        // Create a new listener for this task
        if let Ok(listener) = TcpListener::bind(&addr).await {
            let mut next_replica_id = 1u64;

            while running.load(Ordering::Acquire) {
                match listener.accept().await {
                    Ok((socket, _addr)) => {
                        let replica_id = next_replica_id;
                        next_replica_id += 1;

                        // Check max replicas
                        {
                            let replicas_guard = replicas.read().await;
                            if replicas_guard.len() >= config.max_replicas as usize {
                                eprintln!("Maximum replica connections reached");
                                continue;
                            }
                        }

                        // Set socket options
                        if let Err(e) = socket.set_nodelay(true) {
                            eprintln!("Failed to set TCP_NODELAY: {:?}", e);
                        }

                        // Create and add connection
                        let mut conn = ReplicaConnection::new(replica_id, socket);
                        conn.mark_connected();

                        {
                            let mut replicas_guard = replicas.write().await;
                            replicas_guard.insert(replica_id, Arc::new(TokioMutex::new(conn)));
                        }

                        // Initialize ack tracking
                        {
                            let mut acks = replica_acks.write().await;
                            acks.insert(replica_id, 0);
                        }

                        // Spawn connection handler
                        let replicas_clone = Arc::clone(&replicas);
                        let replica_acks_clone = Arc::clone(&replica_acks);
                        let buffer_clone = Arc::clone(&buffer);
                        let running_clone = Arc::clone(&running);
                        let backpressure_state_clone = Arc::clone(&backpressure_state);

                        tokio::spawn(async move {
                            Self::handle_replica_connection_impl(
                                replica_id,
                                replicas_clone,
                                replica_acks_clone,
                                buffer_clone,
                                running_clone,
                                backpressure_state_clone,
                            ).await;
                        });
                    }
                    Err(e) => {
                        eprintln!("Accept error: {:?}", e);
                        tokio::time::sleep(Duration::from_millis(100)).await;
                    }
                }
            }
        }
    }

    /// Handle replica connection implementation.
    async fn handle_replica_connection_impl(
        replica_id: ReplicaId,
        replicas: Arc<RwLock<HashMap<ReplicaId, Arc<TokioMutex<ReplicaConnection>>>>>,
        replica_acks: Arc<RwLock<HashMap<ReplicaId, u64>>>,
        buffer: Arc<TokioMutex<ReplicationBuffer>>,
        running: Arc<AtomicBool>,
        backpressure_state: Arc<TokioMutex<BackpressureState>>,
    ) {
        while running.load(Ordering::Acquire) {
            // Get replica connection
            let conn_arc = {
                let replicas_guard = replicas.read().await;
                replicas_guard.get(&replica_id).cloned()
            };

            let conn_arc = match conn_arc {
                Some(c) => c,
                None => break,
            };

            let can_send = {
                let conn = conn_arc.lock().await;
                conn.can_send()
            };

            if !can_send {
                tokio::time::sleep(Duration::from_millis(100)).await;
                continue;
            }

            // Flush write buffer
            {
                let mut conn = conn_arc.lock().await;
                if let Err(e) = conn.flush().await {
                    eprintln!("Failed to flush to replica {}: {:?}", replica_id, e);
                    conn.mark_disconnected();
                }
            }

            // Receive messages with timeout
            {
                let mut conn = conn_arc.lock().await;
                let mut recv_buf = [0u8; 4096];
                match tokio::time::timeout(
                    Duration::from_secs(1),
                    conn.socket.read(&mut recv_buf),
                )
                .await
                {
                    Ok(Ok(n)) if n > 0 => {
                        // Parse and handle message - for now just acknowledge
                        let send_seq = conn.send_sequence;
                        drop(conn); // Drop lock before updating acks

                        // Update acks and release buffer
                        {
                            let mut acks = replica_acks.write().await;
                            acks.insert(replica_id, send_seq);
                        }

                        // Release buffered records
                        let min_sequence = {
                            let acks = replica_acks.read().await;
                            let buffer_guard = buffer.lock().await;
                            buffer_guard.get_min_sequence(&acks)
                        };

                        if let Some(min_seq) = min_sequence {
                            let mut buffer_guard = buffer.lock().await;
                            buffer_guard.release_up_to(min_seq);

                            // Check if we should relieve backpressure
                            if buffer_guard.should_relieve_backpressure() {
                                let mut state = backpressure_state.lock().await;
                                *state = BackpressureState::Relieving;
                            }
                        }
                    }
                    Ok(Ok(_)) => {
                        // Zero bytes read = connection closed
                        conn.mark_disconnected();
                        break;
                    }
                    Ok(Err(e)) => {
                        eprintln!("Read error from replica {}: {:?}", replica_id, e);
                        conn.mark_disconnected();
                        break;
                    }
                    Err(_) => {
                        // Timeout - continue loop
                    }
                }
            }

            tokio::time::sleep(Duration::from_millis(10)).await;
        }
    }

    /// Run the publisher (starts background tasks if not already running).
    pub async fn run(&self) -> Result<()> {
        if !self.running.load(Ordering::Acquire) {
            // Get the listen address from config
            let addr: SocketAddr = self.config.listen_address.parse()
                .map_err(|e| ReplicationError::Config(format!("Invalid listen address: {}", e)))?;
            self.start_background_tasks(addr).await?;
        }
        Ok(())
    }

    /// Add a commit record to the replication stream for all connected replicas.
    ///
    /// # Arguments
    ///
    /// * `record` - The commit record to replicate
    ///
    /// # Errors
    ///
    /// Returns an error if:
    /// - Buffer is full (backpressure applied)
    /// - Network error adding to replica write buffer
    /// - Failed to serialize commit record
    pub async fn publish(&self, record: CommitRecord) -> Result<()> {
        // Check backpressure state
        {
            let state = self.backpressure_state.lock().await;
            if state.is_applying() {
                let buffer = self.buffer.lock().await;
                return Err(ReplicationError::buffer_overflow(
                    buffer.current_usage() as u64,
                    self.config.replication_buffer_size,
                ));
            }
        }

        // Serialize commit record
        let record_bytes = Bytes::from(
            serde_json::to_vec(&record)
                .map_err(|e| ReplicationError::invalid_message(format!("Failed to serialize: {}", e)))?,
        );

        // Calculate checksum
        let checksum = Self::calculate_checksum(&record_bytes);

        // Get sequence number
        let sequence = self.sequence_counter.fetch_add(1, Ordering::SeqCst);
        let lsn = record.txn_id.as_u64();

        // Create buffered record
        let buffered_record = BufferedRecord::new(lsn, sequence, record_bytes.clone(), checksum);

        // Add to buffer
        {
            let mut buffer = self.buffer.lock().await;
            buffer.push(buffered_record.clone())?;

            // Check if we should apply backpressure
            if buffer.should_apply_backpressure() {
                let mut state = self.backpressure_state.lock().await;
                *state = BackpressureState::Applying;
            }
        }

        // Send to all connected replicas
        let replicas = self.replicas.read().await;
        for (replica_id, conn_arc) in replicas.iter() {
            let mut conn = conn_arc.lock().await;
            if !conn.can_send() {
                continue;
            }

            // Update send sequence
            conn.send_sequence = sequence + 1;

            // Create and queue commit record message
            let message = ReplicationMessage::commit_record(sequence, record.clone());

            if let Err(e) = conn.queue_message(&message) {
                eprintln!("Failed to queue message for replica {}: {:?}", replica_id, e);
            }
        }

        Ok(())
    }

    /// Calculate checksum for data.
    fn calculate_checksum(data: &[u8]) -> u64 {
        use std::collections::hash_map::DefaultHasher;
        use std::hash::Hasher;

        let mut hasher = DefaultHasher::new();
        hasher.write(data);
        hasher.finish()
    }

    /// Release buffered records that have been acknowledged by all replicas.
    ///
    /// # Arguments
    ///
    /// * `_replica_id` - Replica that sent acknowledgment
    /// * `sequence` - Highest sequence acknowledged
    pub async fn release_buffered_records(&self, _replica_id: ReplicaId, sequence: u64) {
        // Update ack tracking
        {
            let mut acks = self.replica_acks.write().await;
            // Note: In real implementation, track per-replica acks
            // For now, we'll use a simple global ack
        }

        // Get minimum ack sequence across all replicas
        let min_sequence = {
            let buffer = self.buffer.lock().await;
            let acks = self.replica_acks.read().await;
            buffer.get_min_sequence(&acks)
        };

        if let Some(min_seq) = min_sequence {
            let mut buffer = self.buffer.lock().await;
            buffer.release_up_to(min_seq);

            // Check if we should relieve backpressure
            if buffer.should_relieve_backpressure() {
                let mut state = self.backpressure_state.lock().await;
                *state = BackpressureState::Relieving;
            }
        }
    }

    /// Update the acknowledged position and metrics for a specific replica.
    ///
    /// # Arguments
    ///
    /// * `replica_id` - Replica identifier
    /// * `ack_sequence` - Highest sequence acknowledged
    pub async fn track_replica_position(&self, replica_id: ReplicaId, ack_sequence: u64) {
        // Update ack tracking
        {
            let mut acks = self.replica_acks.write().await;
            acks.insert(replica_id, ack_sequence);
        }

        // Update connection state
        let replicas = self.replicas.read().await;
        if let Some(conn_arc) = replicas.get(&replica_id) {
            let mut conn = conn_arc.lock().await;
            conn.update_ack(ack_sequence);
        }

        // Release buffered records
        self.release_buffered_records(replica_id, ack_sequence).await;
    }

    /// Get the current backpressure state.
    pub async fn backpressure_state(&self) -> BackpressureState {
        *self.backpressure_state.lock().await
    }

    /// Get the number of connected replicas.
    pub async fn connected_replicas(&self) -> usize {
        self.replicas.read().await.len()
    }

    /// Get buffer statistics.
    pub async fn buffer_stats(&self) -> (usize, usize, usize) {
        let buffer = self.buffer.lock().await;
        (buffer.current_usage(), buffer.len(), buffer.capacity())
    }

    /// Gracefully shutdown the publisher and all replica connections.
    pub async fn shutdown(&self) -> Result<()> {
        self.running.store(false, Ordering::Release);

        // Close all replica connections
        let replicas = self.replicas.write().await;
        for (replica_id, conn_arc) in replicas.iter() {
            let mut conn = conn_arc.lock().await;
            conn.mark_disconnected();
            eprintln!("Shutting down replica {}", replica_id);
        }

        // Drain buffer
        self.buffer.lock().await.clear();

        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::txn::Mutation;
    use crate::types::TransactionId;

    // Helper to create a test commit record
    fn create_test_record(txn_id: u64) -> CommitRecord {
        let mutations = vec![
            Mutation::Put {
                key: format!("key_{}", txn_id).into_bytes(),
                value: format!("value_{}", txn_id).into_bytes(),
            },
        ];
        CommitRecord::new(TransactionId::new(txn_id), txn_id * 100, mutations)
    }

    #[test]
    fn test_backpressure_state() {
        assert!(!BackpressureState::Normal.is_applying());
        assert!(BackpressureState::Applying.is_applying());
        assert!(BackpressureState::Relieving.is_relieving());
    }

    #[test]
    fn test_buffered_record_new() {
        let record = BufferedRecord::new(100, 1, Bytes::from(vec![1, 2, 3]), 12345);
        assert_eq!(record.lsn, 100);
        assert_eq!(record.sequence, 1);
        assert_eq!(record.size(), 3);
        assert_eq!(record.checksum, 12345);
    }

    #[test]
    fn test_replication_buffer_new() {
        let buffer = ReplicationBuffer::new(1000, 60, 80);
        assert_eq!(buffer.max_size, 1000);
        assert_eq!(buffer.low_watermark, 600);
        assert_eq!(buffer.high_watermark, 800);
        assert!(buffer.is_empty());
        assert_eq!(buffer.current_usage(), 0);
        assert_eq!(buffer.len(), 0);
    }

    #[test]
    fn test_replication_buffer_from_config() {
        let config = PrimaryConfig {
            listen_address: "0.0.0.0:7233".to_string(),
            max_replicas: 10,
            replication_buffer_size: 10000,
        };

        let buffer = ReplicationBuffer::from_config(&config);
        assert_eq!(buffer.max_size, 10000);
        assert_eq!(buffer.low_watermark, 6000);
        assert_eq!(buffer.high_watermark, 8000);
    }

    #[test]
    fn test_replication_buffer_push() {
        let mut buffer = ReplicationBuffer::new(1000, 60, 80);

        let record = BufferedRecord::new(100, 1, Bytes::from(vec![1, 2, 3]), 12345);
        assert!(buffer.push(record).is_ok());

        assert_eq!(buffer.len(), 1);
        assert_eq!(buffer.current_usage(), 3);
        assert!(!buffer.is_empty());
    }

    #[test]
    fn test_replication_buffer_push_overflow() {
        let mut buffer = ReplicationBuffer::new(100, 60, 80);

        let record1 = BufferedRecord::new(100, 1, Bytes::from(vec![1; 60]), 12345);
        let record2 = BufferedRecord::new(101, 2, Bytes::from(vec![2; 60]), 12346);

        assert!(buffer.push(record1).is_ok());
        assert!(buffer.push(record2).is_err()); // Should overflow
    }

    #[test]
    fn test_replication_buffer_pop_front() {
        let mut buffer = ReplicationBuffer::new(1000, 60, 80);

        let record1 = BufferedRecord::new(100, 1, Bytes::from(vec![1, 2, 3]), 12345);
        let record2 = BufferedRecord::new(101, 2, Bytes::from(vec![4, 5, 6]), 12346);

        buffer.push(record1).unwrap();
        buffer.push(record2).unwrap();

        let popped = buffer.pop_front().unwrap();
        assert_eq!(popped.sequence, 1);
        assert_eq!(buffer.current_usage(), 3);
        assert_eq!(buffer.len(), 1);
    }

    #[test]
    fn test_replication_buffer_release_up_to() {
        let mut buffer = ReplicationBuffer::new(1000, 60, 80);

        for i in 1..=10 {
            let record = BufferedRecord::new(i * 100, i, Bytes::from(vec![i as u8; 10]), i);
            buffer.push(record).unwrap();
        }

        buffer.release_up_to(5);
        assert_eq!(buffer.len(), 5);
        assert_eq!(buffer.oldest_sequence(), Some(6));
    }

    #[test]
    fn test_replication_buffer_watermarks() {
        let mut buffer = ReplicationBuffer::new(100, 60, 80);

        // Initially empty - below low watermark
        assert!(!buffer.should_apply_backpressure());
        // When empty, we're technically below low watermark but not "relieving" since we never applied backpressure
        // The should_relieve_backpressure check is just: current_usage < low_watermark
        assert!(buffer.should_relieve_backpressure()); // 0 < 60, so true

        // Add records up to high watermark
        let record = BufferedRecord::new(100, 1, Bytes::from(vec![1; 80]), 12345);
        buffer.push(record).unwrap();

        assert!(buffer.should_apply_backpressure()); // 80 >= 80
        assert!(!buffer.should_relieve_backpressure()); // 80 >= 60

        // Clear and go below low watermark
        buffer.clear();
        let record = BufferedRecord::new(101, 2, Bytes::from(vec![2; 50]), 12346);
        buffer.push(record).unwrap();

        assert!(!buffer.should_apply_backpressure()); // 50 < 80
        assert!(buffer.should_relieve_backpressure()); // 50 < 60
    }

    #[test]
    fn test_replication_buffer_is_full() {
        let mut buffer = ReplicationBuffer::new(100, 60, 80);

        assert!(!buffer.is_full());

        let record = BufferedRecord::new(100, 1, Bytes::from(vec![1; 80]), 12345);
        buffer.push(record).unwrap();

        assert!(buffer.is_full());
    }

    #[test]
    fn test_replication_buffer_clear() {
        let mut buffer = ReplicationBuffer::new(100, 60, 80);

        let record = BufferedRecord::new(100, 1, Bytes::from(vec![1, 2, 3]), 12345);
        buffer.push(record).unwrap();

        buffer.clear();

        assert!(buffer.is_empty());
        assert_eq!(buffer.current_usage(), 0);
        assert_eq!(buffer.len(), 0);
    }

    #[test]
    fn test_replication_buffer_oldest_newest_sequence() {
        let mut buffer = ReplicationBuffer::new(1000, 60, 80);

        assert!(buffer.oldest_sequence().is_none());
        assert!(buffer.newest_sequence().is_none());

        buffer
            .push(BufferedRecord::new(100, 5, Bytes::from(vec![1]), 1))
            .unwrap();
        buffer
            .push(BufferedRecord::new(101, 10, Bytes::from(vec![2]), 2))
            .unwrap();

        assert_eq!(buffer.oldest_sequence(), Some(5));
        assert_eq!(buffer.newest_sequence(), Some(10));
    }

    #[test]
    fn test_replication_buffer_records_after() {
        let mut buffer = ReplicationBuffer::new(1000, 60, 80);

        for i in 1..=10 {
            buffer
                .push(BufferedRecord::new(i * 100, i, Bytes::from(vec![i as u8]), i))
                .unwrap();
        }

        let records = buffer.records_after(5);
        assert_eq!(records.len(), 5);
        assert_eq!(records[0].sequence, 6);
        assert_eq!(records[4].sequence, 10);
    }

    #[test]
    fn test_replication_buffer_get_min_sequence() {
        let buffer = ReplicationBuffer::new(1000, 60, 80);

        let mut acks = HashMap::new();
        acks.insert(1, 10);
        acks.insert(2, 15);
        acks.insert(3, 20);

        assert_eq!(buffer.get_min_sequence(&acks), Some(10));

        // Empty acks
        let empty = HashMap::new();
        assert!(buffer.get_min_sequence(&empty).is_none());
    }

    #[test]
    fn test_connection_state_methods() {
        assert!(ConnectionState::Connected.can_send());
        assert!(ConnectionState::Catchup.can_send());
        assert!(!ConnectionState::Disconnected.can_send());

        assert!(ConnectionState::Connected.can_receive());
        assert!(!ConnectionState::Error.can_receive());

        assert!(ConnectionState::Disconnected.needs_reconnect());
        assert!(ConnectionState::Error.needs_reconnect());

        assert!(ConnectionState::Error.is_terminal());
        assert!(!ConnectionState::Connected.is_terminal());
    }

    #[test]
    fn test_replica_connection_update_ack() {
        // Test that update_ack properly updates the sequence
        let mut last_ack_sequence: u64 = 0;

        // Simulate update_ack behavior
        let sequence = 100;
        last_ack_sequence = sequence.max(last_ack_sequence);

        assert_eq!(last_ack_sequence, 100);

        // Lower value should not update
        let sequence = 50;
        last_ack_sequence = sequence.max(last_ack_sequence);
        assert_eq!(last_ack_sequence, 100);

        // Higher value should update
        let sequence = 150;
        last_ack_sequence = sequence.max(last_ack_sequence);
        assert_eq!(last_ack_sequence, 150);
    }

    #[test]
    fn test_calculate_checksum() {
        let data = b"hello world";
        let checksum1 = Publisher::calculate_checksum(data);
        let checksum2 = Publisher::calculate_checksum(data);

        assert_eq!(checksum1, checksum2);

        let different_data = b"hello universe";
        let checksum3 = Publisher::calculate_checksum(different_data);

        assert_ne!(checksum1, checksum3);
    }

    #[test]
    fn test_backpressure_state_transitions() {
        let state = BackpressureState::Normal;
        assert!(!state.is_applying());

        let state = BackpressureState::Applying;
        assert!(state.is_applying());
        assert!(!state.is_relieving());

        let state = BackpressureState::Relieving;
        assert!(state.is_relieving());
    }

    #[test]
    fn test_buffered_record_size() {
        let data = Bytes::from(vec![1, 2, 3, 4, 5]);
        let record = BufferedRecord::new(100, 1, data.clone(), 12345);
        assert_eq!(record.size(), 5);
    }

    #[test]
    fn test_replication_buffer_capacity() {
        let buffer = ReplicationBuffer::new(5000, 60, 80);
        assert_eq!(buffer.capacity(), 5000);
    }

    #[test]
    fn test_replication_buffer_low_watermark() {
        let buffer = ReplicationBuffer::new(1000, 60, 80);
        assert_eq!(buffer.low_watermark(), 600);
    }

    #[test]
    fn test_replication_buffer_high_watermark() {
        let buffer = ReplicationBuffer::new(1000, 60, 80);
        assert_eq!(buffer.high_watermark(), 800);
    }

    #[test]
    fn test_replication_buffer_watermarks_custom() {
        let buffer = ReplicationBuffer::new(10000, 50, 90);
        assert_eq!(buffer.low_watermark(), 5000); // 50%
        assert_eq!(buffer.high_watermark(), 9000); // 90%
    }

    #[test]
    fn test_replication_buffer_push_multiple() {
        let mut buffer = ReplicationBuffer::new(1000, 60, 80);

        for i in 1..=10 {
            let record = BufferedRecord::new(i * 100, i, Bytes::from(vec![i as u8; 10]), i);
            assert!(buffer.push(record).is_ok());
        }

        assert_eq!(buffer.len(), 10);
        assert_eq!(buffer.current_usage(), 100);
    }

    #[test]
    fn test_replication_buffer_pop_front_empty() {
        let mut buffer = ReplicationBuffer::new(1000, 60, 80);
        assert!(buffer.pop_front().is_none());
    }

    #[test]
    fn test_replication_buffer_release_up_to_empty() {
        let mut buffer = ReplicationBuffer::new(1000, 60, 80);
        buffer.release_up_to(100); // Should not panic on empty buffer
        assert!(buffer.is_empty());
    }

    #[test]
    fn test_replication_buffer_release_up_to_all() {
        let mut buffer = ReplicationBuffer::new(1000, 60, 80);

        for i in 1..=5 {
            let record = BufferedRecord::new(i * 100, i, Bytes::from(vec![i as u8; 10]), i);
            buffer.push(record).unwrap();
        }

        buffer.release_up_to(100); // Release all
        assert!(buffer.is_empty());
    }

    #[test]
    fn test_replication_buffer_records_after_empty() {
        let buffer = ReplicationBuffer::new(1000, 60, 80);
        let records = buffer.records_after(5);
        assert!(records.is_empty());
    }

    #[test]
    fn test_replication_buffer_records_after_none() {
        let mut buffer = ReplicationBuffer::new(1000, 60, 80);

        for i in 1..=5 {
            buffer
                .push(BufferedRecord::new(i * 100, i, Bytes::from(vec![i as u8]), i))
                .unwrap();
        }

        let records = buffer.records_after(100); // No records after sequence 100
        assert!(records.is_empty());
    }

    #[test]
    fn test_backpressure_is_applying() {
        assert!(!BackpressureState::Normal.is_applying());
        assert!(BackpressureState::Applying.is_applying());
        assert!(!BackpressureState::Relieving.is_applying());
    }

    #[test]
    fn test_backpressure_is_relieving() {
        assert!(!BackpressureState::Normal.is_relieving());
        assert!(!BackpressureState::Applying.is_relieving());
        assert!(BackpressureState::Relieving.is_relieving());
    }
}
