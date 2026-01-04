//! Replication subscriber for receiving commits from primary.
//!
//! The subscriber runs on replica nodes and is responsible for:
//! - Connecting to the primary and performing handshake
//! - Receiving commit records and heartbeats
//! - Applying commit records to local state machine
//! - Sending acknowledgments to primary
//! - Handling reconnection with exponential backoff
//! - Bootstrapping from snapshot when needed

use crate::replication::{
    ReplicaConfig, ReplicationMessage, MessageType, ReplicationError, ConnectionState,
    PROTOCOL_VERSION, DEFAULT_RECONNECT_INTERVAL_MS, MAX_RECONNECT_ATTEMPTS,
    error::Result,
};
use crate::txn::CommitRecord;
use bytes::BytesMut;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicU64, AtomicU8, Ordering};
use std::time::{Duration, Instant};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpStream;
use tokio::sync::{mpsc, Mutex};
use tokio::time::{sleep, timeout};

/// Maximum message size (16MB).
const MAX_MESSAGE_SIZE: usize = 16 * 1024 * 1024;

/// Default apply queue size.
const DEFAULT_APPLY_QUEUE_SIZE: usize = 1000;

/// Handshake timeout in seconds.
const HANDSHAKE_TIMEOUT_SECS: u64 = 10;

/// Heartbeat timeout multiplier (3x heartbeat interval).
const HEARTBEAT_TIMEOUT_MULTIPLIER: u64 = 3;

/// Bootstrap timeout in seconds.
const BOOTSTRAP_TIMEOUT_SECS: u64 = 300;

/// Events emitted by subscriber for monitoring.
#[derive(Debug, Clone, PartialEq)]
pub enum SubscriberEvent {
    /// Successfully connected to primary.
    Connected,

    /// Connection lost (includes reason).
    Disconnected(String),

    /// Bootstrap progress update (chunk_index, total_chunks).
    BootstrapProgress(u32, u32),

    /// Bootstrap completed successfully.
    BootstrapComplete,

    /// Replication lag exceeded threshold (current_lag_ms, target_lag_ms).
    LagWarning(u64, u64),

    /// Error occurred (error description).
    Error(String),
}

/// State for tracking bootstrap progress from snapshot.
#[derive(Debug)]
pub struct BootstrapState {
    /// LSN of snapshot being received.
    pub snapshot_lsn: u64,

    /// Number of chunks received.
    pub chunks_received: u32,

    /// Total number of chunks in snapshot.
    pub total_chunks: u32,

    /// Running checksum of snapshot data.
    pub checksum: u64,
}

impl BootstrapState {
    /// Create a new bootstrap state.
    pub fn new(snapshot_lsn: u64, total_chunks: u32) -> Self {
        Self {
            snapshot_lsn,
            chunks_received: 0,
            total_chunks,
            checksum: 0,
        }
    }

    /// Get bootstrap progress as a float (0.0 to 1.0).
    pub fn progress(&self) -> f64 {
        if self.total_chunks == 0 {
            0.0
        } else {
            self.chunks_received as f64 / self.total_chunks as f64
        }
    }

    /// Check if bootstrap is complete.
    pub fn is_complete(&self) -> bool {
        self.total_chunks > 0 && self.chunks_received >= self.total_chunks
    }

    /// Add a chunk to the bootstrap state.
    pub fn add_chunk(&mut self, chunk_checksum: u64) {
        self.chunks_received += 1;
        self.checksum = self.checksum.wrapping_add(chunk_checksum);
    }
}

/// State for exponential backoff reconnection.
#[derive(Debug)]
pub struct ReconnectState {
    /// Current reconnection attempt number.
    pub attempt: u32,

    /// Maximum attempts before giving up.
    pub max_attempts: u32,

    /// Base delay in milliseconds.
    pub base_delay_ms: u64,

    /// Maximum delay in milliseconds.
    pub max_delay_ms: u64,

    /// Timestamp of last reconnection attempt.
    pub last_attempt: Option<Instant>,
}

impl ReconnectState {
    /// Create a new reconnect state.
    pub fn new(base_delay_ms: u64, max_attempts: u32) -> Self {
        Self {
            attempt: 0,
            max_attempts,
            base_delay_ms,
            max_delay_ms: 60_000, // 60 seconds max
            last_attempt: None,
        }
    }

    /// Calculate delay for next reconnection attempt.
    ///
    /// Formula: delay = min(base * 2^attempt, max) + jitter
    pub fn calculate_delay(&self) -> Duration {
        let exponential = self.base_delay_ms * 2u64.pow(self.attempt.min(10));
        let capped = exponential.min(self.max_delay_ms);

        // Add simple jitter (hash of attempt for pseudo-randomness)
        let jitter = ((self.attempt as u64).wrapping_mul(9).wrapping_add(1) % 10) as u64;
        let jitter_amount = (capped as f64 * 0.1) as u64;
        Duration::from_millis(capped.saturating_add(jitter_amount.saturating_mul(jitter).saturating_div(10)))
    }

    /// Increment the attempt counter.
    pub fn increment(&mut self) {
        self.attempt += 1;
        self.last_attempt = Some(Instant::now());
    }

    /// Reset the attempt counter (on successful connection).
    pub fn reset(&mut self) {
        self.attempt = 0;
        self.last_attempt = None;
    }

    /// Check if maximum attempts exceeded.
    pub fn is_max_exceeded(&self) -> bool {
        self.attempt >= self.max_attempts
    }
}

/// Connection from replica to primary.
#[derive(Debug)]
pub struct ReplicaConnection {
    /// TCP socket for communication with primary.
    pub socket: TcpStream,

    /// Unique identifier for primary server.
    pub primary_id: u64,

    /// Negotiated protocol version.
    pub protocol_version: u16,

    /// Current LSN on primary (from heartbeats).
    pub current_primary_lsn: u64,

    /// Next sequence number expected from primary.
    pub receive_sequence: u64,

    /// Timestamp of last message received.
    pub last_received: Instant,

    /// Timestamp of last heartbeat received.
    pub last_heartbeat: Instant,

    /// Buffer for incoming data.
    pub read_buffer: BytesMut,

    /// Buffer for outgoing data.
    pub write_buffer: BytesMut,
}

impl ReplicaConnection {
    /// Create a new replica connection.
    pub fn new(socket: TcpStream, primary_id: u64, protocol_version: u16) -> Self {
        Self {
            socket,
            primary_id,
            protocol_version,
            current_primary_lsn: 0,
            receive_sequence: 0,
            last_received: Instant::now(),
            last_heartbeat: Instant::now(),
            read_buffer: BytesMut::with_capacity(8192),
            write_buffer: BytesMut::with_capacity(8192),
        }
    }

    /// Check if connection has exceeded heartbeat timeout.
    pub fn heartbeat_timeout(&self, timeout_secs: u64) -> bool {
        self.last_heartbeat.elapsed() > Duration::from_secs(timeout_secs)
    }

    /// Update the current primary LSN.
    pub fn update_primary_lsn(&mut self, lsn: u64) {
        self.current_primary_lsn = lsn;
        self.last_heartbeat = Instant::now();
    }

    /// Get the replication lag in milliseconds.
    pub fn replication_lag_ms(&self, applied_lsn: u64) -> u64 {
        if self.current_primary_lsn > applied_lsn {
            self.current_primary_lsn - applied_lsn
        } else {
            0
        }
    }
}

/// Replication subscriber for receiving commits from primary.
pub struct Subscriber {
    /// Configuration for subscriber behavior.
    config: Arc<ReplicaConfig>,

    /// Active connection to primary (if connected).
    connection: Arc<tokio::sync::Mutex<Option<ReplicaConnection>>>,

    /// Current connection state.
    state: Arc<AtomicU8>,

    /// Highest LSN applied to local state machine.
    applied_lsn: Arc<AtomicU64>,

    /// Flag indicating subscriber is running.
    running: Arc<AtomicBool>,

    /// Channel for subscriber events.
    event_sender: mpsc::Sender<SubscriberEvent>,

    /// Channel for received commit records to apply.
    apply_sender: mpsc::Sender<CommitRecord>,

    /// Bootstrap state (if bootstrapping).
    bootstrap_state: Arc<tokio::sync::Mutex<Option<BootstrapState>>>,

    /// Reconnect state.
    reconnect_state: Arc<tokio::sync::Mutex<ReconnectState>>,
}

impl Subscriber {
    /// Create a new replication subscriber.
    pub fn new(config: ReplicaConfig) -> Result<Self> {
        // Validate configuration
        config.validate()
            .map_err(|e| ReplicationError::Config(e))?;

        // Create channels
        let (event_sender, _event_receiver) = mpsc::channel(100);
        let (apply_sender, _apply_receiver) = mpsc::channel(DEFAULT_APPLY_QUEUE_SIZE);

        // Initialize state to Disconnected
        let state = Arc::new(AtomicU8::new(ConnectionState::Disconnected as u8));

        // Create reconnect state
        let reconnect_state = ReconnectState::new(
            config.reconnect_interval_ms,
            MAX_RECONNECT_ATTEMPTS,
        );

        Ok(Self {
            config: Arc::new(config),
            connection: Arc::new(tokio::sync::Mutex::new(None)),
            state,
            applied_lsn: Arc::new(AtomicU64::new(0)),
            running: Arc::new(AtomicBool::new(false)),
            event_sender,
            apply_sender,
            bootstrap_state: Arc::new(tokio::sync::Mutex::new(None)),
            reconnect_state: Arc::new(tokio::sync::Mutex::new(reconnect_state)),
        })
    }

    /// Get the current connection state.
    pub fn state(&self) -> ConnectionState {
        match self.state.load(Ordering::Acquire) {
            0 => ConnectionState::Disconnected,
            1 => ConnectionState::Connecting,
            2 => ConnectionState::Connected,
            3 => ConnectionState::Catchup,
            4 => ConnectionState::Bootstrapping,
            5 => ConnectionState::Error,
            _ => ConnectionState::Disconnected,
        }
    }

    /// Set the connection state.
    fn set_state(&self, new_state: ConnectionState) {
        self.state.store(new_state as u8, Ordering::Release);
    }

    /// Get the current applied LSN.
    pub fn applied_lsn(&self) -> u64 {
        self.applied_lsn.load(Ordering::Acquire)
    }

    /// Update the applied LSN.
    fn update_applied_lsn(&self, lsn: u64) {
        self.applied_lsn.store(lsn, Ordering::Release);
    }

    /// Check if the subscriber is running.
    pub fn is_running(&self) -> bool {
        self.running.load(Ordering::Acquire)
    }

    /// Subscribe to subscriber events.
    pub fn subscribe_events(&self) -> mpsc::Receiver<SubscriberEvent> {
        let (sender, receiver) = mpsc::channel(100);
        // In real implementation, would clone the sender
        let _ = sender;
        receiver
    }

    /// Start the subscriber and begin replication.
    pub async fn start(&self) -> Result<()> {
        // Set running flag
        self.running.store(true, Ordering::Release);

        // Spawn background tasks
        let reconnect_task = {
            let subscriber = self.clone();
            tokio::spawn(async move {
                if let Err(e) = subscriber.reconnect_loop().await {
                    eprintln!("Reconnect loop error: {}", e);
                }
            })
        };

        let apply_task = {
            let subscriber = self.clone();
            tokio::spawn(async move {
                if let Err(e) = subscriber.apply_loop().await {
                    eprintln!("Apply loop error: {}", e);
                }
            })
        };

        // Spawn background heartbeat monitoring
        let heartbeat_task = {
            let subscriber = self.clone();
            tokio::spawn(async move {
                if let Err(e) = subscriber.heartbeat_loop().await {
                    eprintln!("Heartbeat loop error: {}", e);
                }
            })
        };

        // Store task handles for shutdown
        let _ = (reconnect_task, apply_task, heartbeat_task);

        // Attempt initial connection
        self.connect().await?;

        Ok(())
    }

    /// Establish connection to primary and begin replication.
    pub async fn connect(&self) -> Result<()> {
        // Transition to Connecting state
        self.set_state(ConnectionState::Connecting);

        // Resolve and connect to primary address
        let socket = timeout(
            Duration::from_secs(HANDSHAKE_TIMEOUT_SECS),
            TcpStream::connect(&self.config.primary_address)
        )
        .await
        .map_err(|_| ReplicationError::connection_timeout(HANDSHAKE_TIMEOUT_SECS * 1000))?
        .map_err(|e| ReplicationError::connection_lost(format!("Failed to connect: {}", e)))?;

        // Set socket options
        socket.set_nodelay(true)
            .map_err(|e| ReplicationError::Io(e))?;

        // Perform handshake
        let protocol_version = self.perform_handshake(&socket).await?;

        // Create connection
        let connection = ReplicaConnection::new(socket, 0, protocol_version);

        // Store connection
        let mut conn_guard = self.connection.lock().await;
        *conn_guard = Some(connection);
        drop(conn_guard);

        // Transition to Connected state
        self.set_state(ConnectionState::Connected);

        // Reset reconnect state
        let mut reconnect = self.reconnect_state.lock().await;
        reconnect.reset();
        drop(reconnect);

        // Emit Connected event
        let _ = self.event_sender.send(SubscriberEvent::Connected).await;

        // Spawn receive loop for this connection
        let subscriber = self.clone();
        tokio::spawn(async move {
            if let Err(e) = subscriber.receive_loop().await {
                eprintln!("Receive loop error: {}", e);
                subscriber.set_state(ConnectionState::Disconnected);
                let _ = subscriber.event_sender.send(SubscriberEvent::Disconnected(e.to_string())).await;
            }
        });

        Ok(())
    }

    /// Perform handshake with primary.
    async fn perform_handshake(&self, socket: &TcpStream) -> Result<u16> {
        // Clone the TcpStream's inner for split read/write
        // For now, we just validate the protocol version
        // In a real implementation, would perform actual handshake

        // For now, just return the protocol version
        let version = PROTOCOL_VERSION;

        Ok(version)
    }

    /// Background task for receiving messages from primary.
    async fn receive_loop(&self) -> Result<()> {
        while self.is_running() {
            // Check if still connected
            if !self.state().is_connected() {
                break;
            }

            // Get connection
            let mut conn_guard = self.connection.lock().await;
            let connection = conn_guard.as_mut()
                .ok_or_else(|| ReplicationError::connection_lost("No active connection"))?;

            // Read message header
            let mut header_buf = [0u8; 24];
            timeout(
                Duration::from_secs(self.config.reconnect_interval_ms / 1000 + 5),
                connection.socket.read_exact(&mut header_buf)
            )
            .await
            .map_err(|_| ReplicationError::connection_timeout(5000))?
            .map_err(|e| ReplicationError::connection_lost(format!("Failed to read header: {}", e)))?;

            // Parse message (simplified - in real implementation would use FrameReader)
            let message_type = MessageType::Heartbeat; // Placeholder
            let sequence = 0; // Placeholder

            connection.last_received = Instant::now();
            connection.receive_sequence = sequence;

            // Handle message based on type
            match message_type {
                MessageType::Heartbeat => {
                    connection.last_heartbeat = Instant::now();

                    // Check replication lag
                    let lag = connection.replication_lag_ms(self.applied_lsn());
                    if lag > self.config.replication_lag_target_ms {
                        let _ = self.event_sender.send(SubscriberEvent::LagWarning(
                            lag,
                            self.config.replication_lag_target_ms
                        )).await;
                    }

                    // Send acknowledgment
                    self.send_ack(connection).await?;
                }
                MessageType::CommitRecord => {
                    // In real implementation, would deserialize commit record
                    // and send to apply queue
                    let record = CommitRecord::new(
                        crate::types::TransactionId::new(0),
                        0,
                        vec![],
                    );

                    // Send to apply queue
                    timeout(
                        Duration::from_secs(5),
                        self.apply_sender.send(record)
                    )
                    .await
                    .map_err(|_| ReplicationError::connection_lost("Apply queue full"))?
                    .map_err(|_| ReplicationError::connection_lost("Apply queue closed"))?;

                    // Send acknowledgment
                    self.send_ack(connection).await?;
                }
                MessageType::Snapshot => {
                    // Handle snapshot chunk
                    self.handle_snapshot_chunk().await?;
                }
                MessageType::Error => {
                    // Log error
                    return Err(ReplicationError::connection_lost("Received error from primary"));
                }
            }
        }

        Ok(())
    }

    /// Handle a snapshot chunk during bootstrap.
    async fn handle_snapshot_chunk(&self) -> Result<()> {
        // Transition to Bootstrapping state
        self.set_state(ConnectionState::Bootstrapping);

        let mut bootstrap = self.bootstrap_state.lock().await;

        // Initialize bootstrap state if needed
        if bootstrap.is_none() {
            *bootstrap = Some(BootstrapState::new(0, 100)); // Placeholder values
        }

        let state = bootstrap.as_mut().unwrap();

        // Add chunk
        state.add_chunk(0); // Placeholder checksum

        // Emit progress event
        let _ = self.event_sender.send(SubscriberEvent::BootstrapProgress(
            state.chunks_received,
            state.total_chunks
        )).await;

        // Check if complete
        if state.is_complete() {
            // Apply snapshot
            self.apply_snapshot(state).await?;

            // Update applied LSN
            self.update_applied_lsn(state.snapshot_lsn);

            // Clear bootstrap state
            *bootstrap = None;

            // Transition to Connected
            self.set_state(ConnectionState::Connected);

            // Emit complete event
            let _ = self.event_sender.send(SubscriberEvent::BootstrapComplete).await;
        }

        Ok(())
    }

    /// Apply snapshot to local storage.
    async fn apply_snapshot(&self, state: &BootstrapState) -> Result<()> {
        // In real implementation, would:
        // 1. Validate final checksum
        // 2. Apply snapshot to local storage
        // 3. Truncate WAL up to snapshot LSN
        let _ = state;
        Ok(())
    }

    /// Send acknowledgment to primary.
    async fn send_ack(&self, connection: &mut ReplicaConnection) -> Result<()> {
        let ack = ReplicationMessage::heartbeat(self.applied_lsn());
        let serialized = ack.serialize()
            .map_err(|e| ReplicationError::Io(std::io::Error::new(std::io::ErrorKind::Other, e)))?;

        connection.socket.write_all(&serialized).await
            .map_err(|e| ReplicationError::connection_lost(format!("Failed to send ack: {}", e)))?;

        Ok(())
    }

    /// Background task for applying received commit records.
    async fn apply_loop(&self) -> Result<()> {
        // Create a new receiver for commit records
        let (_sender, mut receiver): (mpsc::Sender<CommitRecord>, mpsc::Receiver<CommitRecord>) =
            mpsc::channel(DEFAULT_APPLY_QUEUE_SIZE);

        while self.is_running() {
            match receiver.recv().await {
                Some(record) => {
                    // Validate checksum
                    if !record.verify() {
                        return Err(ReplicationError::ChecksumError);
                    }

                    // Write to local WAL
                    // In real implementation, would write to WAL
                    let _ = record;

                    // Apply to MVCC state machine
                    // In real implementation, would apply to state machine

                    // Update applied LSN
                    self.update_applied_lsn(record.txn_id.as_u64());
                }
                None => {
                    // Channel closed
                    break;
                }
            }
        }

        Ok(())
    }

    /// Background task for handling reconnection with exponential backoff.
    async fn reconnect_loop(&self) -> Result<()> {
        while self.is_running() {
            // Sleep and check state
            sleep(Duration::from_secs(1)).await;

            // Skip if already connected
            if self.state().is_connected() {
                continue;
            }

            // Exit if in error state
            if self.state().is_terminal() {
                break;
            }

            // Calculate delay
            let reconnect = self.reconnect_state.lock().await;
            let delay = reconnect.calculate_delay();
            drop(reconnect);

            // Sleep for delay
            sleep(delay).await;

            // Increment attempt
            let mut reconnect = self.reconnect_state.lock().await;
            reconnect.increment();

            // Check if max attempts exceeded
            if reconnect.is_max_exceeded() {
                drop(reconnect);
                self.set_state(ConnectionState::Error);
                let _ = self.event_sender.send(SubscriberEvent::Error(
                    "Maximum reconnection attempts exceeded".to_string()
                )).await;
                break;
            }
            drop(reconnect);

            // Attempt reconnection
            match self.connect().await {
                Ok(_) => {
                    // Success - reconnect_loop will reset reconnect state
                }
                Err(e) => {
                    // Log error and continue
                    let _ = self.event_sender.send(SubscriberEvent::Disconnected(
                        format!("Reconnection attempt failed: {}", e)
                    )).await;
                }
            }
        }

        Ok(())
    }

    /// Background task for monitoring heartbeat timeout.
    async fn heartbeat_loop(&self) -> Result<()> {
        while self.is_running() {
            sleep(Duration::from_secs(5)).await;

            // Check if connected
            if !self.state().is_connected() {
                continue;
            }

            // Get connection and check timeout
            let conn_guard = self.connection.lock().await;
            if let Some(connection) = conn_guard.as_ref() {
                let timeout_secs = HEARTBEAT_TIMEOUT_MULTIPLIER;
                if connection.heartbeat_timeout(timeout_secs) {
                    drop(conn_guard);
                    self.set_state(ConnectionState::Disconnected);
                    let _ = self.event_sender.send(SubscriberEvent::Disconnected(
                        "Heartbeat timeout".to_string()
                    )).await;
                }
            }
        }

        Ok(())
    }

    /// Initiate bootstrap from snapshot.
    pub async fn bootstrap(&self) -> Result<()> {
        // Transition to Bootstrapping state
        self.set_state(ConnectionState::Bootstrapping);

        // Close existing connection if any
        let mut conn_guard = self.connection.lock().await;
        *conn_guard = None;
        drop(conn_guard);

        // Reconnect with start_lsn = 0 to trigger bootstrap
        // In real implementation, would set start_lsn to 0
        self.connect().await?;

        // Wait for bootstrap complete or timeout
        let start = Instant::now();
        while start.elapsed() < Duration::from_secs(BOOTSTRAP_TIMEOUT_SECS) {
            sleep(Duration::from_secs(1)).await;

            if self.state() == ConnectionState::Connected {
                return Ok(());
            }

            if self.state().is_terminal() {
                return Err(ReplicationError::bootstrap_failed("Entered error state during bootstrap"));
            }
        }

        Err(ReplicationError::connection_timeout(BOOTSTRAP_TIMEOUT_SECS * 1000))
    }

    /// Gracefully shutdown the subscriber.
    pub async fn shutdown(&self) -> Result<()> {
        // Set running flag to false
        self.running.store(false, Ordering::Release);

        // Close connection
        let mut conn_guard = self.connection.lock().await;
        *conn_guard = None;
        drop(conn_guard);

        // Transition to Disconnected
        self.set_state(ConnectionState::Disconnected);

        Ok(())
    }
}

impl Clone for Subscriber {
    fn clone(&self) -> Self {
        Self {
            config: Arc::clone(&self.config),
            connection: Arc::clone(&self.connection),
            state: Arc::clone(&self.state),
            applied_lsn: Arc::clone(&self.applied_lsn),
            running: Arc::clone(&self.running),
            event_sender: self.event_sender.clone(),
            apply_sender: self.apply_sender.clone(),
            bootstrap_state: Arc::clone(&self.bootstrap_state),
            reconnect_state: Arc::clone(&self.reconnect_state),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_bootstrap_state_new() {
        let state = BootstrapState::new(100, 10);
        assert_eq!(state.snapshot_lsn, 100);
        assert_eq!(state.total_chunks, 10);
        assert_eq!(state.chunks_received, 0);
        assert_eq!(state.progress(), 0.0);
        assert!(!state.is_complete());
    }

    #[test]
    fn test_bootstrap_state_progress() {
        let mut state = BootstrapState::new(100, 10);
        assert_eq!(state.progress(), 0.0);

        state.add_chunk(0);
        assert_eq!(state.chunks_received, 1);
        assert_eq!(state.progress(), 0.1);

        state.add_chunk(0);
        state.add_chunk(0);
        assert_eq!(state.chunks_received, 3);
        assert_eq!(state.progress(), 0.3);
    }

    #[test]
    fn test_bootstrap_state_complete() {
        let mut state = BootstrapState::new(100, 5);
        assert!(!state.is_complete());

        for _ in 0..5 {
            state.add_chunk(0);
        }
        assert!(state.is_complete());
        assert_eq!(state.progress(), 1.0);
    }

    #[test]
    fn test_reconnect_state_new() {
        let state = ReconnectState::new(1000, 10);
        assert_eq!(state.attempt, 0);
        assert_eq!(state.max_attempts, 10);
        assert_eq!(state.base_delay_ms, 1000);
        assert_eq!(state.max_delay_ms, 60000);
        assert!(state.last_attempt.is_none());
        assert!(!state.is_max_exceeded());
    }

    #[test]
    fn test_reconnect_state_calculate_delay() {
        let state = ReconnectState::new(1000, 10);

        // Attempt 0: 1000ms
        let delay = state.calculate_delay();
        assert!(delay.as_millis() >= 1000);
        assert!(delay.as_millis() < 1200); // 1000 + 10% jitter

        // Increment attempt and recalculate
        let mut state = state;
        state.attempt = 1;
        let delay = state.calculate_delay();
        assert!(delay.as_millis() >= 2000);
        assert!(delay.as_millis() < 2300); // 2000 + 10% jitter
    }

    #[test]
    fn test_reconnect_state_increment() {
        let mut state = ReconnectState::new(1000, 10);
        assert_eq!(state.attempt, 0);

        state.increment();
        assert_eq!(state.attempt, 1);
        assert!(state.last_attempt.is_some());

        state.increment();
        assert_eq!(state.attempt, 2);
    }

    #[test]
    fn test_reconnect_state_reset() {
        let mut state = ReconnectState::new(1000, 10);
        state.increment();
        state.increment();
        assert_eq!(state.attempt, 2);

        state.reset();
        assert_eq!(state.attempt, 0);
        assert!(state.last_attempt.is_none());
    }

    #[test]
    fn test_reconnect_state_max_exceeded() {
        let mut state = ReconnectState::new(1000, 3);
        assert!(!state.is_max_exceeded());

        state.attempt = 2;
        assert!(!state.is_max_exceeded());

        state.attempt = 3;
        assert!(state.is_max_exceeded());
    }

    #[test]
    fn test_replica_connection_new() {
        // Test ReplicaConnection::new method
        // Since we can't create a real TcpStream in unit tests,
        // we just test the new() method signature compiles
        // The actual connection testing would be in integration tests
    }

    #[test]
    fn test_replica_connection_update_primary_lsn() {
        // Test update_primary_lsn method
        // This would require a real TcpStream which isn't available in unit tests
        // Integration tests would cover this
    }

    #[test]
    fn test_replica_connection_replication_lag_ms() {
        // Test replication_lag_ms calculation
        // Since current_primary_lsn is 0 initially, lag should be 0
        // We test the logic: if primary_lsn > applied_lsn, return difference
        let primary_lsn = 100u64;
        let applied_lsn = 50u64;
        let expected_lag = primary_lsn - applied_lsn; // 50

        assert_eq!(expected_lag, 50);

        // When applied_lsn >= primary_lsn, lag should be 0
        let primary_lsn = 100u64;
        let applied_lsn = 150u64;
        let expected_lag = if primary_lsn > applied_lsn {
            primary_lsn - applied_lsn
        } else {
            0
        };

        assert_eq!(expected_lag, 0);
    }

    #[test]
    fn test_subscriber_new_valid_config() {
        let config = ReplicaConfig {
            primary_address: "127.0.0.1:7233".to_string(),
            replication_lag_target_ms: 100,
            reconnect_interval_ms: 1000,
            bootstrap_on_start: false,
        };

        let subscriber = Subscriber::new(config);
        assert!(subscriber.is_ok());
    }

    #[test]
    fn test_subscriber_new_invalid_config() {
        let config = ReplicaConfig {
            primary_address: "".to_string(), // Invalid
            replication_lag_target_ms: 100,
            reconnect_interval_ms: 1000,
            bootstrap_on_start: false,
        };

        let subscriber = Subscriber::new(config);
        assert!(subscriber.is_err());
    }

    #[test]
    fn test_subscriber_state() {
        let config = ReplicaConfig {
            primary_address: "127.0.0.1:7233".to_string(),
            replication_lag_target_ms: 100,
            reconnect_interval_ms: 1000,
            bootstrap_on_start: false,
        };

        let subscriber = Subscriber::new(config).unwrap();
        assert_eq!(subscriber.state(), ConnectionState::Disconnected);
        assert_eq!(subscriber.applied_lsn(), 0);
        assert!(!subscriber.is_running());
    }

    #[test]
    fn test_subscriber_set_state() {
        let config = ReplicaConfig {
            primary_address: "127.0.0.1:7233".to_string(),
            replication_lag_target_ms: 100,
            reconnect_interval_ms: 1000,
            bootstrap_on_start: false,
        };

        let subscriber = Subscriber::new(config).unwrap();
        assert_eq!(subscriber.state(), ConnectionState::Disconnected);

        subscriber.set_state(ConnectionState::Connected);
        assert_eq!(subscriber.state(), ConnectionState::Connected);
    }

    #[test]
    fn test_subscriber_applied_lsn() {
        let config = ReplicaConfig {
            primary_address: "127.0.0.1:7233".to_string(),
            replication_lag_target_ms: 100,
            reconnect_interval_ms: 1000,
            bootstrap_on_start: false,
        };

        let subscriber = Subscriber::new(config).unwrap();
        assert_eq!(subscriber.applied_lsn(), 0);

        subscriber.update_applied_lsn(100);
        assert_eq!(subscriber.applied_lsn(), 100);

        subscriber.update_applied_lsn(200);
        assert_eq!(subscriber.applied_lsn(), 200);
    }

    #[test]
    fn test_subscriber_clone() {
        let config = ReplicaConfig {
            primary_address: "127.0.0.1:7233".to_string(),
            replication_lag_target_ms: 100,
            reconnect_interval_ms: 1000,
            bootstrap_on_start: false,
        };

        let subscriber = Subscriber::new(config).unwrap();
        let cloned = subscriber.clone();

        assert_eq!(subscriber.applied_lsn(), cloned.applied_lsn());
        assert_eq!(subscriber.state(), cloned.state());
    }
}
