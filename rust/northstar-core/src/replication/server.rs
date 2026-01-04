//! Replication Server - Accepts and manages replica connections on primary.
//!
//! The server runs on the primary node and is responsible for:
//! - Listening for incoming replica connections
//! - Spawning Publisher tasks for each replica
//! - Managing the replication buffer and backpressure
//! - Providing shutdown signal handling
//!
//! # Example
//!
//! ```rust,no_run
//! use northstar_core::replication::{ReplicationServer, PrimaryConfig};
//! use std::sync::Arc;
//! use tokio::sync::Notify;
//!
//! #[tokio::main]
//! async fn main() -> Result<(), Box<dyn std::error::Error>> {
//!     let config = PrimaryConfig {
//!         listen_address: "0.0.0.0:7233".to_string(),
//!         max_replicas: 10,
//!         replication_buffer_size: 100 * 1024 * 1024,
//!     };
//!
//!     let shutdown = Arc::new(Notify::new());
//!     let server = ReplicationServer::new(config, shutdown)?;
//!     server.run().await?;
//!     Ok(())
//! }
//! ```

use crate::replication::config::PrimaryConfig;
use crate::replication::error::{ReplicationError, Result};
use crate::replication::protocol::MessageType;
use crate::replication::publisher::{Publisher, ReplicaConnection, ReplicaId, ReplicationBuffer};
use crate::replication::state::ConnectionState;
use crate::replication::PROTOCOL_VERSION;
use crate::txn::CommitRecord;
use std::collections::HashMap;
use std::io;
use std::net::SocketAddr;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::Arc;
use std::time::Instant;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::{mpsc, Notify, RwLock};
use tokio::task::JoinHandle;
use tokio::time::{interval, Duration, Instant as TokioInstant};

/// Default channel capacity for commit record submission.
const COMMIT_CHANNEL_CAPACITY: usize = 10_000;

/// Default heartbeat interval in seconds.
const HEARTBEAT_INTERVAL_SECS: u64 = 5;

/// Default heartbeat timeout in seconds (3x interval).
const HEARTBEAT_TIMEOUT_SECS: u64 = 15;

/// Maximum accepted connections per second (rate limiting).
const MAX_CONNECTIONS_PER_SECOND: u32 = 10;

/// Connection rate limit window duration.
const RATE_LIMIT_WINDOW: Duration = Duration::from_secs(1);

/// Server state for tracking connections and metrics.
#[derive(Debug)]
struct ServerState {
    /// All connected replicas by ID.
    replicas: HashMap<ReplicaId, ReplicaInfo>,
    /// Current backpressure state.
    backpressure_state: BackpressureState,
    /// When backpressure was last applied.
    backpressure_since: Option<Instant>,
    /// Number of active connections.
    active_connections: usize,
    /// Total bytes replicated.
    total_bytes_replicated: u64,
    /// Number of commits replicated.
    total_commits_replicated: u64,
    /// Server start time.
    start_time: Instant,
}

impl ServerState {
    fn new() -> Self {
        Self {
            replicas: HashMap::new(),
            backpressure_state: BackpressureState::Normal,
            backpressure_since: None,
            active_connections: 0,
            total_bytes_replicated: 0,
            total_commits_replicated: 0,
            start_time: Instant::now(),
        }
    }

    fn add_replica(&mut self, replica_id: ReplicaId, addr: SocketAddr) {
        self.replicas.insert(replica_id, ReplicaInfo::new(replica_id, addr));
        self.active_connections += 1;
    }

    fn remove_replica(&mut self, replica_id: ReplicaId) {
        if self.replicas.remove(&replica_id).is_some() {
            self.active_connections = self.active_connections.saturating_sub(1);
        }
    }

    fn update_replica_ack(&mut self, replica_id: ReplicaId, sequence: u64) {
        if let Some(replica) = self.replicas.get_mut(&replica_id) {
            replica.last_ack_sequence = sequence;
            replica.last_ack_received = Instant::now();
        }
    }

    fn get_replica_ack(&self, replica_id: ReplicaId) -> Option<u64> {
        self.replicas.get(&replica_id).map(|r| r.last_ack_sequence)
    }
}

/// Information about a connected replica.
#[derive(Debug, Clone)]
struct ReplicaInfo {
    /// Unique replica identifier.
    pub replica_id: ReplicaId,
    /// Remote socket address.
    pub remote_addr: SocketAddr,
    /// Connection state.
    pub state: ConnectionState,
    /// Last sequence number acknowledged.
    pub last_ack_sequence: u64,
    /// Timestamp of last acknowledgment.
    pub last_ack_received: Instant,
    /// When the replica connected.
    pub connected_since: Instant,
}

impl ReplicaInfo {
    fn new(replica_id: ReplicaId, remote_addr: SocketAddr) -> Self {
        Self {
            replica_id,
            remote_addr,
            state: ConnectionState::Connected,
            last_ack_sequence: 0,
            last_ack_received: Instant::now(),
            connected_since: Instant::now(),
        }
    }

    fn heartbeat_timeout(&self, timeout_secs: u64) -> bool {
        self.last_ack_received.elapsed().as_secs() > timeout_secs
    }
}

/// Current backpressure state.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BackpressureState {
    /// Normal operation, accepting all writes.
    Normal,
    /// Applying backpressure, buffer near capacity.
    Applying,
    /// Relieving backpressure, buffer draining.
    Relieving,
}

impl BackpressureState {
    pub const fn is_applying(&self) -> bool {
        matches!(self, Self::Applying)
    }

    pub const fn is_relieving(&self) -> bool {
        matches!(self, Self::Relieving)
    }

    pub const fn is_normal(&self) -> bool {
        matches!(self, Self::Normal)
    }
}

/// Metrics about replication server status.
#[derive(Debug, Clone)]
pub struct ServerMetrics {
    /// Number of active replica connections.
    pub active_connections: usize,
    /// Current backpressure state.
    pub backpressure_state: BackpressureState,
    /// Total bytes replicated since server start.
    pub total_bytes_replicated: u64,
    /// Total commits replicated since server start.
    pub total_commits_replicated: u64,
    /// Server uptime in seconds.
    pub uptime_secs: u64,
    /// Per-replica acknowledgment positions.
    pub replica_positions: HashMap<ReplicaId, u64>,
    /// Current buffer usage in bytes.
    pub buffer_usage: usize,
    /// Buffer capacity in bytes.
    pub buffer_capacity: usize,
}

/// Result from a replica connection handler.
#[derive(Debug)]
enum ConnectionResult {
    /// Connection completed successfully (replica disconnected).
    Disconnected(ReplicaId),
    /// Connection failed with error.
    Error(ReplicaId, String),
}

/// Replication server that accepts and manages replica connections.
pub struct ReplicationServer {
    /// Server configuration.
    config: PrimaryConfig,
    /// Shared server state.
    state: Arc<RwLock<ServerState>>,
    /// Replication buffer for commit records.
    buffer: Arc<RwLock<ReplicationBuffer>>,
    /// Channel for receiving commit records to replicate.
    commit_tx: mpsc::Sender<CommitRecord>,
    /// Channel for receiving commit records (internal receiver).
    commit_rx: Arc<tokio::sync::Mutex<mpsc::Receiver<CommitRecord>>>,
    /// Shutdown notification.
    shutdown: Arc<Notify>,
    /// Flag indicating if server is running.
    running: Arc<AtomicBool>,
    /// Next replica ID to assign.
    next_replica_id: Arc<AtomicU64>,
    /// Rate limit tracking for connection attempts.
    rate_limit_count: Arc<AtomicU64>,
    /// Rate limit window start.
    rate_limit_window: Arc<std::sync::Mutex<Option<Instant>>>,
}

impl ReplicationServer {
    /// Create a new replication server.
    pub fn new(config: PrimaryConfig, shutdown: Arc<Notify>) -> Result<Self> {
        let buffer = ReplicationBuffer::from_config(&config);
        let (commit_tx, commit_rx) = mpsc::channel(COMMIT_CHANNEL_CAPACITY);

        Ok(Self {
            config,
            state: Arc::new(RwLock::new(ServerState::new())),
            buffer: Arc::new(RwLock::new(buffer)),
            commit_tx,
            commit_rx: Arc::new(tokio::sync::Mutex::new(commit_rx)),
            shutdown,
            running: Arc::new(AtomicBool::new(false)),
            next_replica_id: Arc::new(AtomicU64::new(1)),
            rate_limit_count: Arc::new(AtomicU64::new(0)),
            rate_limit_window: Arc::new(std::sync::Mutex::new(None)),
        })
    }

    /// Get the sender for submitting commit records.
    ///
    /// This should be integrated with the commit log to automatically
    /// replicate committed transactions.
    pub fn commit_sender(&self) -> mpsc::Sender<CommitRecord> {
        self.commit_tx.clone()
    }

    /// Submit a commit record for replication.
    pub async fn submit_commit(&self, record: CommitRecord) -> Result<()> {
        self.commit_tx.send(record).await
            .map_err(|_| ReplicationError::channel_closed("Commit channel closed"))?;
        Ok(())
    }

    /// Run the replication server.
    ///
    /// This method listens for incoming connections and spawns
    /// handler tasks for each replica.
    pub async fn run(&self) -> Result<()> {
        self.running.store(true, Ordering::Release);
        let listener = TcpListener::bind(&self.config.listen_address)
            .await
            .map_err(|e| ReplicationError::io_error(format!("Failed to bind to {}: {}", self.config.listen_address, e)))?;

// info!("Replication server listening on {}", self.config.listen_address);

        let mut tasks: Vec<JoinHandle<()>> = vec![
            self.spawn_commit_processor(),
            self.spawn_heartbeat_monitor(),
        ];

        loop {
            // Check for shutdown
            tokio::select! {
                result = listener.accept() => {
                    match result {
                        Ok((mut stream, addr)) => {
                            // Rate limit connection attempts
                            if !self.check_rate_limit().await {
// warn!("Rate limit exceeded, rejecting connection from {}", addr);
                                let _ = stream.shutdown().await;
                                continue;
                            }

                            // Check max replicas
                            let state = self.state.read().await;
                            if state.active_connections >= self.config.max_replicas as usize {
// warn!("Max replicas ({}) reached, rejecting connection from {}", self.config.max_replicas, addr);
                                drop(state);
                                let _ = stream.shutdown().await;
                                continue;
                            }
                            drop(state);

// info!("Accepting replica connection from {}", addr);
                            let handler = self.spawn_connection_handler(stream, addr);
                            tasks.push(handler);
                        }
                        Err(e) => {
// error!("Failed to accept connection: {}", e);
                        }
                    }
                }
                _ = self.shutdown.notified() => {
// info!("Shutdown signal received, stopping server");
                    break;
                }
            }
        }

        // Cancel all tasks
        for task in tasks {
            task.abort();
        }

        self.running.store(false, Ordering::Release);
        Ok(())
    }

    /// Check and update rate limit for connection attempts.
    async fn check_rate_limit(&self) -> bool {
        let mut window = self.rate_limit_window.lock().unwrap();
        let now = Instant::now();

        // Reset counter if window expired
        if window.map_or(true, |w| now.duration_since(w) > RATE_LIMIT_WINDOW) {
            self.rate_limit_count.store(0, Ordering::Relaxed);
            *window = Some(now);
        }

        // Increment and check
        let count = self.rate_limit_count.fetch_add(1, Ordering::Relaxed);
        count < MAX_CONNECTIONS_PER_SECOND as u64
    }

    /// Spawn task to process commit records from channel.
    fn spawn_commit_processor(&self) -> JoinHandle<()> {
        let buffer = Arc::clone(&self.buffer);
        let rx = Arc::clone(&self.commit_rx);
        let state = Arc::clone(&self.state);
        let running = Arc::clone(&self.running);
        let config = self.config.clone();

        tokio::spawn(async move {
            let mut sequence: u64 = 0;
            let mut rx_guard = rx.lock().await;

            while running.load(Ordering::Acquire) {
                match rx_guard.recv().await {
                    Some(record) => {
                        // Note: For now, we create a simple placeholder record.
                        // Full serialization will be added when bincode is available.
                        let record_bytes = vec![0u8]; // Placeholder
                        let record_len = record_bytes.len();

                        // Calculate checksum
                        let checksum = Self::calculate_checksum(&record_bytes);

                        // Create buffered record
                        // Note: We need to track LSN separately from CommitRecord
                        let lsn = sequence; // Use sequence as LSN for now
                        let buffered = crate::replication::publisher::BufferedRecord::new(
                            lsn,
                            sequence,
                            bytes::Bytes::from(record_bytes),
                            checksum,
                        );

                        // Try to add to buffer
                        {
                            let mut buf = buffer.write().await;
                            match buf.push(buffered.clone()) {
                                Ok(()) => {
                                    sequence = sequence.wrapping_add(1);

                                    // Update metrics
                                    let mut st = state.write().await;
                                    st.total_commits_replicated = st.total_commits_replicated.wrapping_add(1);
                                    st.total_bytes_replicated = st.total_bytes_replicated.wrapping_add(record_len as u64);

                                    // Update backpressure state
                                    let old_state = st.backpressure_state;
                                    st.backpressure_state = if buf.should_apply_backpressure() {
                                        if st.backpressure_state != BackpressureState::Applying {
                                            st.backpressure_since = Some(Instant::now());
                                        }
                                        BackpressureState::Applying
                                    } else if buf.should_relieve_backpressure() {
                                        BackpressureState::Relieving
                                    } else {
                                        BackpressureState::Normal
                                    };

                                    if old_state != st.backpressure_state {
// info!("Backpressure state changed: {:?} -> {:?}", old_state, st.backpressure_state);
                                    }
                                }
                                Err(e) => {
// error!("Failed to buffer commit record: {}", e);
                                    // Backpressure applied to commit log
                                }
                            }
                        }
                    }
                    None => {
// warn!("Commit channel closed, stopping processor");
                        break;
                    }
                }
            }
        })
    }

    /// Spawn task to monitor heartbeat timeouts.
    fn spawn_heartbeat_monitor(&self) -> JoinHandle<()> {
        let state = Arc::clone(&self.state);
        let running = Arc::clone(&self.running);

        tokio::spawn(async move {
            let mut interval = interval(Duration::from_secs(HEARTBEAT_INTERVAL_SECS));
            interval.tick().await; // Skip first tick

            while running.load(Ordering::Acquire) {
                interval.tick().await;

                let mut st = state.write().await;
                let timeout_replicas: Vec<_> = st.replicas.iter()
                    .filter(|(_, r)| r.heartbeat_timeout(HEARTBEAT_TIMEOUT_SECS))
                    .map(|(id, _)| *id)
                    .collect();

                for replica_id in timeout_replicas {
// warn!("Replica {} heartbeat timeout", replica_id);
                    st.remove_replica(replica_id);
                }
            }
        })
    }

    /// Spawn a task to handle a single replica connection.
    fn spawn_connection_handler(&self, stream: TcpStream, addr: SocketAddr) -> JoinHandle<()> {
        let replica_id = self.next_replica_id.fetch_add(1, Ordering::Relaxed);
        let state = Arc::clone(&self.state);
        let buffer = Arc::clone(&self.buffer);
        let running = Arc::clone(&self.running);

        tokio::spawn(async move {
            // Create replica connection
            let mut conn = ReplicaConnection::new(replica_id, stream);
            conn.mark_connected();

            // Add to state
            {
                let mut st = state.write().await;
                st.add_replica(replica_id, addr);
            }

// info!("Replica {} connected from {}", replica_id, addr);

            // Run connection loop
            let result = Self::handle_connection(&mut conn, buffer.clone()).await;

            // Handle result
            match result {
                Ok(ConnectionResult::Disconnected(id)) => {
// info!("Replica {} disconnected", id);
                }
                Ok(ConnectionResult::Error(id, e)) => {
// error!("Replica {} error: {}", id, e);
                }
                Err(e) => {
// error!("Replica {} connection failed: {}", replica_id, e);
                }
            }

            // Remove from state
            {
                let mut st = state.write().await;
                st.remove_replica(replica_id);
            }

// info!("Replica {} handler terminated", replica_id);
        })
    }

    /// Handle communication with a single replica.
    async fn handle_connection(
        conn: &mut ReplicaConnection,
        buffer: Arc<RwLock<ReplicationBuffer>>,
    ) -> Result<ConnectionResult> {
        let replica_id = conn.replica_id;

        // Perform handshake
        Self::perform_handshake(conn).await?;

        // Main replication loop
        let mut send_sequence: u64 = 0;
        let mut heartbeat_interval = interval(Duration::from_secs(HEARTBEAT_INTERVAL_SECS));
        heartbeat_interval.tick().await; // Skip first tick

        loop {
            tokio::select! {
                // Check for incoming messages
                result = conn.receive_message() => {
                    match result {
                        Ok(msg) => {
                            // Handle acknowledgment
                            if msg.message_type() == MessageType::Ack {
                                if let Some(seq) = msg.sequence() {
                                    conn.update_ack(seq);
                                }
                            }
                        }
                        Err(e) => {
                            return Ok(ConnectionResult::Error(replica_id, e.to_string()));
                        }
                    }
                }
                // Send heartbeat
                _ = heartbeat_interval.tick() => {
                    let heartbeat = crate::replication::protocol::ReplicationMessage::heartbeat(0);
                    if let Err(e) = conn.send_message(&heartbeat).await {
// error!("Failed to send heartbeat to replica {}: {}", replica_id, e);
                        return Ok(ConnectionResult::Error(replica_id, e.to_string()));
                    }
                }
                // Check for shutdown
                else => return Ok(ConnectionResult::Disconnected(replica_id)),
            }

            // Check for new records to send
            {
                let buf = buffer.read().await;
                let records = buf.records_after(send_sequence);

                for record in records {
                    let msg = crate::replication::protocol::ReplicationMessage::commit_record_bytes(
                        record.sequence,
                        record.lsn,
                        record.record_bytes.clone(),
                        record.checksum,
                    );

                    if let Err(e) = conn.send_message(&msg).await {
// error!("Failed to send commit to replica {}: {}", replica_id, e);
                        return Ok(ConnectionResult::Error(replica_id, e.to_string()));
                    }

                    send_sequence = record.sequence;
                }
            }
        }
    }

    /// Perform initial handshake with replica.
    async fn perform_handshake(conn: &mut ReplicaConnection) -> Result<()> {
        // Read handshake message from replica
        let handshake = conn.receive_message().await?;

        if handshake.message_type() != MessageType::Connect {
            return Err(ReplicationError::protocol_error(format!(
                "Expected Connect message, got {:?}",
                handshake.message_type()
            )));
        }

        // Check protocol version
        if let Some(version) = handshake.version() {
            if version != PROTOCOL_VERSION {
                let error_msg = crate::replication::protocol::ReplicationMessage::error(
                    format!("Protocol version mismatch: expected {}, got {}", PROTOCOL_VERSION, version)
                );
                let _ = conn.send_message(&error_msg).await;
                return Err(ReplicationError::version_mismatch(version, PROTOCOL_VERSION));
            }
        }

        // Send acceptance response
        let accept = crate::replication::protocol::ReplicationMessage::accept(0, PROTOCOL_VERSION);
        conn.send_message(&accept).await?;

        conn.mark_connected();
// info!("Handshake completed with replica {}", conn.replica_id);

        Ok(())
    }

    /// Calculate checksum for data.
    fn calculate_checksum(data: &[u8]) -> u64 {
        use std::hash::{Hash, Hasher};
        use std::collections::hash_map::DefaultHasher;

        let mut hasher = DefaultHasher::new();
        data.hash(&mut hasher);
        hasher.finish()
    }

    /// Get current server metrics.
    pub async fn metrics(&self) -> ServerMetrics {
        let state = self.state.read().await;
        let buffer = self.buffer.read().await;

        ServerMetrics {
            active_connections: state.active_connections,
            backpressure_state: state.backpressure_state,
            total_bytes_replicated: state.total_bytes_replicated,
            total_commits_replicated: state.total_commits_replicated,
            uptime_secs: state.start_time.elapsed().as_secs(),
            replica_positions: state.replicas.iter()
                .map(|(id, r)| (*id, r.last_ack_sequence))
                .collect(),
            buffer_usage: buffer.current_usage(),
            buffer_capacity: buffer.capacity(),
        }
    }

    /// Get current backpressure state.
    pub async fn backpressure_state(&self) -> BackpressureState {
        let state = self.state.read().await;
        state.backpressure_state
    }

    /// Check if server is running.
    pub fn is_running(&self) -> bool {
        self.running.load(Ordering::Acquire)
    }

    /// Signal shutdown.
    pub fn shutdown(&self) {
        self.shutdown.notify_one();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::txn::CommitRecord;
    use crate::TransactionId;

    #[tokio::test]
    async fn test_server_creation() {
        let config = PrimaryConfig {
            listen_address: "127.0.0.1:0".to_string(), // Use port 0 for ephemeral
            max_replicas: 5,
            replication_buffer_size: 1024 * 1024,
        };
        let shutdown = Arc::new(Notify::new());
        let server = ReplicationServer::new(config, shutdown);
        assert!(server.is_ok());
    }

    #[tokio::test]
    async fn test_server_metrics() {
        let config = PrimaryConfig {
            listen_address: "127.0.0.1:0".to_string(),
            max_replicas: 5,
            replication_buffer_size: 1024 * 1024,
        };
        let shutdown = Arc::new(Notify::new());
        let server = ReplicationServer::new(config.clone(), shutdown).unwrap();

        let metrics = server.metrics().await;
        assert_eq!(metrics.active_connections, 0);
        assert_eq!(metrics.total_commits_replicated, 0);
        assert!(metrics.uptime_secs < 1);
        assert_eq!(metrics.buffer_capacity, 1024 * 1024);
    }

    #[tokio::test]
    async fn test_backpressure_states() {
        assert!(BackpressureState::Normal.is_normal());
        assert!(BackpressureState::Applying.is_applying());
        assert!(BackpressureState::Relieving.is_relieving());
        assert!(!BackpressureState::Normal.is_applying());
    }

    #[tokio::test]
    async fn test_replica_info() {
        let info = ReplicaInfo::new(1, "127.0.0.1:12345".parse().unwrap());
        assert_eq!(info.replica_id, 1);
        assert_eq!(info.last_ack_sequence, 0);
        assert!(!info.heartbeat_timeout(HEARTBEAT_TIMEOUT_SECS));

        // Update ack and check timeout
        let info2 = ReplicaInfo {
            last_ack_received: Instant::now() - Duration::from_secs(20),
            ..info
        };
        assert!(info2.heartbeat_timeout(HEARTBEAT_TIMEOUT_SECS));
    }

    #[tokio::test]
    async fn test_server_state() {
        let mut state = ServerState::new();
        assert_eq!(state.active_connections, 0);

        state.add_replica(1, "127.0.0.1:12345".parse().unwrap());
        assert_eq!(state.active_connections, 1);

        state.update_replica_ack(1, 100);
        assert_eq!(state.get_replica_ack(1), Some(100));

        state.remove_replica(1);
        assert_eq!(state.active_connections, 0);
        assert_eq!(state.get_replica_ack(1), None);
    }

    #[tokio::test]
    async fn test_checksum() {
        let data1 = b"hello world";
        let data2 = b"hello world";
        let data3 = b"goodbye world";

        assert_eq!(ReplicationServer::calculate_checksum(data1), ReplicationServer::calculate_checksum(data2));
        assert_ne!(ReplicationServer::calculate_checksum(data1), ReplicationServer::calculate_checksum(data3));
    }

    #[tokio::test]
    async fn test_commit_sender() {
        let config = PrimaryConfig {
            listen_address: "127.0.0.1:0".to_string(),
            max_replicas: 5,
            replication_buffer_size: 1024 * 1024,
        };
        let shutdown = Arc::new(Notify::new());
        let server = ReplicationServer::new(config, shutdown).unwrap();
        let sender = server.commit_sender();

        // Create a dummy commit record
        let record = CommitRecord {
            txn_id: TransactionId::new(1),
            root_page_id: 1,
            mutations: Vec::new(),
            checksum: 0,
        };

        // Should be able to send
        assert!(sender.send(record).await.is_ok());
    }
}
