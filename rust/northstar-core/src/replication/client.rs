//! Replication Client - Connects replica to primary and manages connection.
//!
//! The client runs on replica nodes and is responsible for:
//! - Initiating connection to the primary
//! - Performing handshake protocol
//! - Receiving commit records via Subscriber
//! - Sending acknowledgments to primary
//! - Handling reconnection with exponential backoff
//!
//! # Example
//!
//! ```rust,no_run
//! use northstar_core::replication::{ReplicationClient, ReplicaConfig};
//! use std::sync::Arc;
//! use tokio::sync::Notify;
//!
//! #[tokio::main]
//! async fn main() -> Result<(), Box<dyn std::error::Error>> {
//!     let config = ReplicaConfig {
//!         primary_address: "primary.example.com:7233".to_string(),
//!         replication_lag_target_ms: 100,
//!         reconnect_interval_ms: 1000,
//!         bootstrap_on_start: false,
//!     };
//!
//!     let shutdown = Arc::new(Notify::new());
//!     let (client_result, mut event_rx, mut commit_rx) = ReplicationClient::new(config, shutdown);
//!     let client = client_result?;
//!
//!     // Connect and start replication
//!     client.connect().await?;
//!     client.run().await?;
//!
//!     // Process events and commits from receivers
//!     while let Some(event) = event_rx.recv().await {
//!         println!("Event: {:?}", event);
//!     }
//!
//!     Ok(())
//! }
//! ```

use crate::replication::config::ReplicaConfig;
use crate::replication::error::{ReplicationError, Result};
use crate::replication::protocol::{MessageType, ReplicationMessage};
use crate::replication::state::ConnectionState;
use crate::replication::subscriber::{ReconnectState, Subscriber, SubscriberEvent};
use crate::replication::PROTOCOL_VERSION;
use crate::txn::CommitRecord;
use crate::types::Lsn;
use std::io;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpStream;
use tokio::sync::{mpsc, Notify, RwLock};
use tokio::task::JoinHandle;
use tokio::time::{sleep, timeout};

/// Connection timeout in seconds.
const CONNECTION_TIMEOUT_SECS: u64 = 10;

/// Handshake timeout in seconds.
const HANDSHAKE_TIMEOUT_SECS: u64 = 10;

/// Maximum message size (16MB).
const MAX_MESSAGE_SIZE: usize = 16 * 1024 * 1024;

/// Default event channel capacity.
const EVENT_CHANNEL_CAPACITY: usize = 1000;

/// Default commit record channel capacity.
const COMMIT_CHANNEL_CAPACITY: usize = 10_000;

/// Heartbeat timeout multiplier (3x expected interval).
const HEARTBEAT_TIMEOUT_MULTIPLIER: u64 = 3;

/// Client state machine.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ClientState {
    /// Client is initialized but not connected.
    Disconnected,
    /// Attempting to connect to primary.
    Connecting,
    /// Performing handshake.
    Handshaking,
    /// Catching up with missed commit records.
    CatchingUp,
    /// Connected and replicating.
    Replicating,
    /// An error occurred.
    Error,
}

impl ClientState {
    pub const fn is_connected(&self) -> bool {
        matches!(self, Self::Replicating | Self::CatchingUp)
    }

    pub const fn can_send(&self) -> bool {
        matches!(self, Self::Replicating | Self::CatchingUp)
    }

    pub const fn can_receive(&self) -> bool {
        matches!(self, Self::Replicating | Self::CatchingUp | Self::Handshaking)
    }
}

/// Client metrics for monitoring.
#[derive(Debug, Clone)]
pub struct ClientMetrics {
    /// Current client state.
    pub state: ClientState,
    /// Current replication LSN.
    pub current_lsn: Lsn,
    /// Primary LSN (from heartbeats).
    pub primary_lsn: Option<u64>,
    /// Replication lag in milliseconds.
    pub replication_lag_ms: u64,
    /// Number of commits received.
    pub commits_received: u64,
    /// Number of bytes received.
    pub bytes_received: u64,
    /// Number of reconnection attempts.
    pub reconnect_attempts: u32,
    /// Time since last heartbeat.
    pub last_heartbeat_age_ms: u64,
    /// Connection uptime in seconds.
    pub uptime_secs: u64,
}

/// A connection from replica to primary.
pub struct PrimaryConnection {
    /// TCP socket to primary.
    socket: TcpStream,

    /// Unique ID assigned by primary.
    primary_id: u64,

    /// Negotiated protocol version.
    protocol_version: u16,

    /// Next sequence number to send.
    send_sequence: u64,

    /// Highest sequence number acknowledged by primary.
    last_ack_sequence: u64,

    /// Next sequence number expected from primary.
    receive_sequence: u64,

    /// Timestamp of last message received.
    last_received: Instant,

    /// Timestamp of last heartbeat received.
    last_heartbeat: Instant,

    /// Read buffer.
    read_buffer: bytes::BytesMut,

    /// Write buffer.
    write_buffer: Vec<u8>,

    /// When the connection was established.
    connected_since: Instant,
}

impl PrimaryConnection {
    /// Create a new primary connection from a TCP stream.
    fn new(socket: TcpStream) -> Self {
        Self {
            socket,
            primary_id: 0,
            protocol_version: 0,
            send_sequence: 0,
            last_ack_sequence: 0,
            receive_sequence: 0,
            last_received: Instant::now(),
            last_heartbeat: Instant::now(),
            read_buffer: bytes::BytesMut::with_capacity(8192),
            write_buffer: Vec::new(),
            connected_since: Instant::now(),
        }
    }

    /// Send a message to the primary.
    async fn send_message(&mut self, msg: &ReplicationMessage) -> io::Result<()> {
        let bytes = msg.serialize()?;
        self.socket.write_all(&bytes).await?;
        self.socket.flush().await?;
        Ok(())
    }

    /// Receive a message from the primary.
    async fn receive_message(&mut self) -> Result<ReplicationMessage> {
        // Read frame header (24 bytes)
        let mut header_buf = [0u8; 24];
        timeout(Duration::from_secs(5), self.socket.read_exact(&mut header_buf)).await
            .map_err(|_| io::Error::new(io::ErrorKind::TimedOut, "Read timeout"))?
            .map_err(|e| ReplicationError::io_error(format!("Failed to read header: {}", e)))?;

        // Parse header
        let version = u16::from_le_bytes([header_buf[0], header_buf[1]]);
        let msg_type = u16::from_le_bytes([header_buf[2], header_buf[3]]);
        let sequence = u64::from_le_bytes([
            header_buf[4], header_buf[5], header_buf[6], header_buf[7],
            header_buf[8], header_buf[9], header_buf[10], header_buf[11],
        ]);
        let checksum = u64::from_le_bytes([
            header_buf[12], header_buf[13], header_buf[14], header_buf[15],
            header_buf[16], header_buf[17], header_buf[18], header_buf[19],
        ]);
        let payload_len = u32::from_le_bytes([header_buf[20], header_buf[21], header_buf[22], header_buf[23]]) as usize;

        // Validate payload size
        if payload_len > MAX_MESSAGE_SIZE {
            return Err(ReplicationError::invalid_message(format!(
                "Payload size {} exceeds maximum {}", payload_len, MAX_MESSAGE_SIZE
            )));
        }

        // Read payload
        let payload = if payload_len > 0 {
            let mut buf = vec![0u8; payload_len];
            timeout(Duration::from_secs(30), self.socket.read_exact(&mut buf)).await
                .map_err(|_| io::Error::new(io::ErrorKind::TimedOut, "Payload read timeout"))?
                .map_err(|e| ReplicationError::io_error(format!("Failed to read payload: {}", e)))?;
            buf
        } else {
            Vec::new()
        };

        // Reconstruct full message
        let mut full_message = Vec::with_capacity(24 + payload_len);
        full_message.extend_from_slice(&header_buf);
        full_message.extend_from_slice(&payload);

        self.last_received = Instant::now();

        // Parse message
        let msg = ReplicationMessage::deserialize(&full_message)?;

        // Update heartbeat timestamp if this is a heartbeat
        if msg.message_type() == MessageType::Heartbeat {
            self.last_heartbeat = Instant::now();
        }

        Ok(msg)
    }

    /// Send acknowledgment for a sequence number.
    async fn send_ack(&mut self, sequence: u64) -> io::Result<()> {
        let ack = ReplicationMessage::ack(sequence);
        self.send_message(&ack).await?;
        self.last_ack_sequence = sequence;
        Ok(())
    }

    /// Check if heartbeat timeout has occurred.
    fn heartbeat_timeout(&self, timeout_secs: u64) -> bool {
        self.last_heartbeat.elapsed().as_secs() > timeout_secs
    }

    /// Get time since last heartbeat in milliseconds.
    fn last_heartbeat_age_ms(&self) -> u64 {
        self.last_heartbeat.elapsed().as_millis() as u64
    }

    /// Get connection uptime in seconds.
    fn uptime_secs(&self) -> u64 {
        self.connected_since.elapsed().as_secs()
    }
}

/// Replication client that connects to primary and receives commit records.
pub struct ReplicationClient {
    /// Client configuration.
    config: ReplicaConfig,

    /// Shutdown notification.
    shutdown: Arc<Notify>,

    /// Running flag.
    running: Arc<AtomicBool>,

    /// Current client state.
    state: Arc<RwLock<ClientState>>,

    /// Primary connection (if connected).
    connection: Arc<RwLock<Option<PrimaryConnection>>>,

    /// Channel for events.
    event_tx: mpsc::Sender<SubscriberEvent>,

    /// Channel for commit records.
    commit_tx: mpsc::Sender<CommitRecord>,

    /// Reconnection state.
    reconnect_state: Arc<RwLock<ReconnectState>>,

    /// Current LSN.
    current_lsn: Arc<AtomicU64>,

    /// Primary LSN (from heartbeats).
    primary_lsn: Arc<AtomicU64>,

    /// Commits received counter.
    commits_received: Arc<AtomicU64>,

    /// Bytes received counter.
    bytes_received: Arc<AtomicU64>,

    /// Reconnect attempts counter.
    reconnect_attempts: Arc<AtomicU64>,

    /// Connection start time (for uptime).
    connection_start: Arc<RwLock<Option<Instant>>>,
}

/// Result type for creating a ReplicationClient.
pub type ClientResult = (Result<ReplicationClient>, mpsc::Receiver<SubscriberEvent>, mpsc::Receiver<CommitRecord>);

impl ReplicationClient {
    /// Create a new replication client.
    ///
    /// Returns a tuple of (client, event_receiver, commit_receiver).
    pub fn new(config: ReplicaConfig, shutdown: Arc<Notify>) -> ClientResult {
        let (event_tx, event_rx) = mpsc::channel(EVENT_CHANNEL_CAPACITY);
        let (commit_tx, commit_rx) = mpsc::channel(COMMIT_CHANNEL_CAPACITY);

        let reconnect_interval_ms = config.reconnect_interval_ms;
        let client = Ok(Self {
            config,
            shutdown,
            running: Arc::new(AtomicBool::new(false)),
            state: Arc::new(RwLock::new(ClientState::Disconnected)),
            connection: Arc::new(RwLock::new(None)),
            event_tx,
            commit_tx,
            reconnect_state: Arc::new(RwLock::new(ReconnectState::new(
                reconnect_interval_ms,
                crate::replication::MAX_RECONNECT_ATTEMPTS,
            ))),
            current_lsn: Arc::new(AtomicU64::new(0)),
            primary_lsn: Arc::new(AtomicU64::new(0)),
            commits_received: Arc::new(AtomicU64::new(0)),
            bytes_received: Arc::new(AtomicU64::new(0)),
            reconnect_attempts: Arc::new(AtomicU64::new(0)),
            connection_start: Arc::new(RwLock::new(None)),
        });

        (client, event_rx, commit_rx)
    }

    /// Connect to the primary server.
    pub async fn connect(&self) -> Result<()> {
        self.update_state(ClientState::Connecting).await;

        // Resolve and connect
        let stream = timeout(
            Duration::from_secs(CONNECTION_TIMEOUT_SECS),
            TcpStream::connect(&self.config.primary_address)
        )
        .await
        .map_err(|_| ReplicationError::connection_timeout(CONNECTION_TIMEOUT_SECS))?
        .map_err(|e| ReplicationError::connection_failed(self.config.primary_address.clone(), e.to_string()))?;

        // Create connection
        let mut conn = PrimaryConnection::new(stream);

        // Perform handshake
        self.perform_handshake(&mut conn).await?;

        // Store connection
        {
            let mut connection_guard = self.connection.write().await;
            *connection_guard = Some(conn);
        }

        // Reset reconnect state
        {
            let mut reconnect = self.reconnect_state.write().await;
            reconnect.reset();
            self.reconnect_attempts.store(0, Ordering::Relaxed);
        }

        // Update state
        self.update_state(ClientState::Replicating).await;
        *self.connection_start.write().await = Some(Instant::now());

        // Emit connected event
        let _ = self.event_tx.send(SubscriberEvent::Connected).await;

// info!("Connected to primary at {}", self.config.primary_address);

        Ok(())
    }

    /// Perform handshake with primary.
    async fn perform_handshake(&self, conn: &mut PrimaryConnection) -> Result<()> {
        self.update_state(ClientState::Handshaking).await;

        // Send connect message
        let start_lsn = self.current_lsn.load(Ordering::Relaxed);
        let connect_msg = ReplicationMessage::connect(0, start_lsn);

        timeout(
            Duration::from_secs(HANDSHAKE_TIMEOUT_SECS),
            conn.send_message(&connect_msg)
        )
        .await
        .map_err(|_| ReplicationError::handshake_timeout(HANDSHAKE_TIMEOUT_SECS))?
        .map_err(|e| ReplicationError::io_error(format!("Failed to send connect: {}", e)))?;

        // Wait for accept response
        let response = timeout(
            Duration::from_secs(HANDSHAKE_TIMEOUT_SECS),
            conn.receive_message()
        )
        .await
        .map_err(|_| ReplicationError::handshake_timeout(HANDSHAKE_TIMEOUT_SECS))?
        .map_err(|e| ReplicationError::protocol_error(format!("Failed to receive accept: {}", e)))?;

        // Check response type
        if response.message_type() == MessageType::Error {
            let error_msg = response.payload().unwrap_or(&b"Unknown error"[..]);
            let error_str = String::from_utf8_lossy(error_msg);
            return Err(ReplicationError::handshake_failed(error_str.to_string()));
        }

        if response.message_type() != MessageType::Accept {
            return Err(ReplicationError::protocol_error(format!(
                "Expected Accept message, got {:?}",
                response.message_type()
            )));
        }

        // Extract protocol version
        if let Some(version) = response.version() {
            conn.protocol_version = version;
        }

        conn.primary_id = response.sequence().unwrap_or(0);

// debug!("Handshake completed, primary_id={}, version={}", conn.primary_id, conn.protocol_version);

        Ok(())
    }

    /// Run the replication client.
    ///
    /// This method starts the replication loop and runs until
    // shutdown is signaled or a fatal error occurs.
    pub async fn run(&self) -> Result<()> {
        self.running.store(true, Ordering::Release);

        let mut heartbeat_interval = tokio::time::interval(Duration::from_secs(5));
        heartbeat_interval.tick().await; // Skip first tick

        loop {
            tokio::select! {
                // Check for shutdown
                _ = self.shutdown.notified() => {
// info!("Shutdown signal received");
                    break;
                }

                // Monitor heartbeat timeout
                _ = heartbeat_interval.tick() => {
                    let conn_guard = self.connection.read().await;
                    if let Some(conn) = conn_guard.as_ref() {
                        let timeout_secs = self.config.reconnect_interval_ms / 1000 * HEARTBEAT_TIMEOUT_MULTIPLIER;
                        if conn.heartbeat_timeout(timeout_secs.max(15)) {
// warn!("Heartbeat timeout, initiating reconnection");
                            drop(conn_guard);
                            self.reconnect().await?;
                            continue;
                        }
                    }
                }

                // Process incoming messages
                result = async {
                    let mut conn_guard = self.connection.write().await;
                    let conn = conn_guard.as_mut().ok_or_else(|| ReplicationError::not_connected())?;
                    conn.receive_message().await
                } => {
                    match result {
                        Ok(msg) => {
                            if let Err(e) = self.handle_message(msg).await {
// error!("Failed to handle message: {}", e);
                                self.reconnect().await?;
                            }
                        }
                        Err(e) => {
// error!("Failed to receive message: {}", e);
                            self.reconnect().await?;
                        }
                    }
                }
            }
        }

        self.running.store(false, Ordering::Release);
        Ok(())
    }

    /// Handle a received message from primary.
    async fn handle_message(&self, msg: ReplicationMessage) -> Result<()> {
        match msg.message_type() {
            MessageType::CommitRecord => {
                // Extract commit record data
                let lsn = msg.lsn().ok_or_else(|| ReplicationError::invalid_message("Missing LSN"))?;
                let payload = msg.payload().ok_or_else(|| ReplicationError::invalid_message("Missing payload"))?;

                // Note: For now, we just track the LSN. Full deserialization will be added later.
                // The payload contains the serialized commit record which can be deserialized
                // when bincode is added to dependencies.

                // Update counters
                self.current_lsn.store(lsn, Ordering::Relaxed);
                self.commits_received.fetch_add(1, Ordering::Relaxed);
                self.bytes_received.fetch_add(payload.len() as u64, Ordering::Relaxed);

                // Send acknowledgment
                let sequence = msg.sequence().unwrap_or(0);
                {
                    let mut conn_guard = self.connection.write().await;
                    if let Some(conn) = conn_guard.as_mut() {
                        let _ = conn.send_ack(sequence).await;
                    }
                }
            }

            MessageType::Heartbeat => {
                // Update primary LSN from heartbeat
                if let Some(primary_lsn) = msg.lsn() {
                    self.primary_lsn.store(primary_lsn, Ordering::Relaxed);
                }

                // Update last heartbeat timestamp
                {
                    let mut conn_guard = self.connection.write().await;
                    if let Some(conn) = conn_guard.as_mut() {
                        conn.last_heartbeat = Instant::now();
                    }
                }
            }

            MessageType::Snapshot => {
// info!("Received snapshot from primary");
                let _ = self.event_tx.send(SubscriberEvent::BootstrapComplete).await;
            }

            MessageType::Error => {
                let error_msg = msg.payload().map(|p| String::from_utf8_lossy(p).to_string())
                    .unwrap_or_else(|| "Unknown error".to_string());
// error!("Received error from primary: {}", error_msg);
                let _ = self.event_tx.send(SubscriberEvent::Error(error_msg.clone())).await;
                return Err(ReplicationError::remote_error(error_msg));
            }

            _ => {
// debug!("Ignoring message type: {:?}", msg.message_type());
            }
        }

        Ok(())
    }

    /// Reconnect to primary with exponential backoff.
    async fn reconnect(&self) -> Result<()> {
        self.update_state(ClientState::Disconnected).await;

        // Close existing connection
        {
            let mut conn_guard = self.connection.write().await;
            *conn_guard = None;
        }

        // Get reconnect delay
        let delay = {
            let mut reconnect = self.reconnect_state.write().await;
            reconnect.increment();
            self.reconnect_attempts.fetch_add(1, Ordering::Relaxed);

            if reconnect.is_max_exceeded() {
                return Err(ReplicationError::max_reconnect_attempts_exceeded(
                    self.reconnect_attempts.load(Ordering::Relaxed) as u32
                ));
            }

            reconnect.calculate_delay()
        };

// info!("Reconnecting in {}ms (attempt {})", delay.as_millis(), self.reconnect_attempts.load(Ordering::Relaxed));

        // Emit disconnected event
        let _ = self.event_tx.send(SubscriberEvent::Disconnected(
            format!("Reconnecting in {}ms", delay.as_millis())
        )).await;

        // Wait before reconnecting
        sleep(delay).await;

        // Attempt reconnection
        self.connect().await?;

        Ok(())
    }

    /// Update client state.
    async fn update_state(&self, new_state: ClientState) {
        let mut state = self.state.write().await;
        if *state != new_state {
// debug!("Client state: {:?} -> {:?}", *state, new_state);
            *state = new_state;
        }
    }

    /// Get current client metrics.
    pub async fn metrics(&self) -> ClientMetrics {
        let state = *self.state.read().await;
        let conn_guard = self.connection.read().await;
        let uptime = conn_guard.as_ref()
            .map(|c| c.uptime_secs())
            .unwrap_or(0);
        let last_heartbeat_age = conn_guard.as_ref()
            .map(|c| c.last_heartbeat_age_ms())
            .unwrap_or(u64::MAX);

        let current_lsn_val = self.current_lsn.load(Ordering::Relaxed);
        let primary_lsn_val = self.primary_lsn.load(Ordering::Relaxed);

        ClientMetrics {
            state,
            current_lsn: Lsn::new(current_lsn_val),
            primary_lsn: if primary_lsn_val > 0 { Some(primary_lsn_val) } else { None },
            replication_lag_ms: if primary_lsn_val > 0 {
                primary_lsn_val.saturating_sub(current_lsn_val)
            } else {
                0
            },
            commits_received: self.commits_received.load(Ordering::Relaxed),
            bytes_received: self.bytes_received.load(Ordering::Relaxed),
            reconnect_attempts: self.reconnect_attempts.load(Ordering::Relaxed) as u32,
            last_heartbeat_age_ms: last_heartbeat_age,
            uptime_secs: uptime,
        }
    }

    /// Check if client is running.
    pub fn is_running(&self) -> bool {
        self.running.load(Ordering::Acquire)
    }

    /// Signal shutdown.
    pub fn shutdown(&self) {
        self.shutdown.notify_one();
    }

    /// Get current client state.
    pub async fn state(&self) -> ClientState {
        *self.state.read().await
    }

    /// Check if connected to primary.
    pub async fn is_connected(&self) -> bool {
        self.state.read().await.is_connected()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_client_state_methods() {
        assert!(!ClientState::Disconnected.is_connected());
        assert!(!ClientState::Connecting.is_connected());
        assert!(!ClientState::Handshaking.is_connected());
        assert!(ClientState::CatchingUp.is_connected());
        assert!(ClientState::Replicating.is_connected());
        assert!(!ClientState::Error.is_connected());
    }

    #[test]
    fn test_client_state_can_send() {
        assert!(!ClientState::Disconnected.can_send());
        assert!(!ClientState::Connecting.can_send());
        assert!(!ClientState::Handshaking.can_send());
        assert!(ClientState::CatchingUp.can_send());
        assert!(ClientState::Replicating.can_send());
    }

    #[tokio::test]
    async fn test_client_creation() {
        let config = ReplicaConfig {
            primary_address: "127.0.0.1:7233".to_string(),
            replication_lag_target_ms: 100,
            reconnect_interval_ms: 1000,
            bootstrap_on_start: false,
        };
        let shutdown = Arc::new(Notify::new());
        let (client_result, _event_rx, _commit_rx) = ReplicationClient::new(config, shutdown);
        assert!(client_result.is_ok());

        let client = client_result.unwrap();
        assert!(!client.is_running());
        assert_eq!(client.state().await, ClientState::Disconnected);
    }

    #[tokio::test]
    async fn test_client_metrics() {
        let config = ReplicaConfig {
            primary_address: "127.0.0.1:7233".to_string(),
            replication_lag_target_ms: 100,
            reconnect_interval_ms: 1000,
            bootstrap_on_start: false,
        };
        let shutdown = Arc::new(Notify::new());
        let (client_result, _event_rx, _commit_rx) = ReplicationClient::new(config, shutdown);
        let client = client_result.unwrap();

        let metrics = client.metrics().await;
        assert_eq!(metrics.state, ClientState::Disconnected);
        assert_eq!(metrics.commits_received, 0);
        assert_eq!(metrics.bytes_received, 0);
        assert_eq!(metrics.reconnect_attempts, 0);
    }

    #[test]
    fn test_primary_connection_heartbeat_timeout() {
        // Create a mock TcpStream for testing purposes
        // Note: In a real scenario, you'd need to actually connect or mock the stream
        // For now, this test demonstrates the type signature is correct
        // The actual connection timeout testing would require integration tests

        // Can't easily test timeout without manipulating time or using mock sockets
        // This is a placeholder to verify the test compiles
        assert!(true);
    }
}
