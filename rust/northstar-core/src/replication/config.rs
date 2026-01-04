//! Replication configuration types.
//!
//! Defines the configuration for primary and replica nodes in the
//! replication topology.

use serde::{Deserialize, Serialize};
use std::net::SocketAddr;

/// Role of a node in the replication topology.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum ReplicationRole {
    /// Primary node accepts writes and streams commit log to replicas.
    Primary,
    /// Replica node receives commit stream and serves read-only queries.
    Replica,
}

impl ReplicationRole {
    /// Returns true if this role is Primary.
    pub const fn is_primary(&self) -> bool {
        matches!(self, Self::Primary)
    }

    /// Returns true if this role is Replica.
    pub const fn is_replica(&self) -> bool {
        matches!(self, Self::Replica)
    }
}

/// Configuration for replication behavior on a node.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ReplicationConfig {
    /// Role of this node (primary or replica).
    pub role: ReplicationRole,

    /// Primary configuration (present when role is Primary).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub primary_config: Option<PrimaryConfig>,

    /// Replica configuration (present when role is Replica).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub replica_config: Option<ReplicaConfig>,
}

impl ReplicationConfig {
    /// Create a new primary configuration.
    pub fn primary(listen_address: String, max_replicas: u32) -> Self {
        Self {
            role: ReplicationRole::Primary,
            primary_config: Some(PrimaryConfig {
                listen_address,
                max_replicas,
                replication_buffer_size: crate::replication::DEFAULT_BUFFER_SIZE,
            }),
            replica_config: None,
        }
    }

    /// Create a new replica configuration.
    pub fn replica(primary_address: String) -> Self {
        Self {
            role: ReplicationRole::Replica,
            primary_config: None,
            replica_config: Some(ReplicaConfig {
                primary_address,
                replication_lag_target_ms: crate::replication::DEFAULT_LAG_TARGET_MS,
                reconnect_interval_ms: crate::replication::DEFAULT_RECONNECT_INTERVAL_MS,
                bootstrap_on_start: false,
            }),
        }
    }

    /// Validate the configuration.
    pub fn validate(&self) -> Result<(), String> {
        match self.role {
            ReplicationRole::Primary => {
                let primary = self.primary_config.as_ref()
                    .ok_or_else(|| "Primary config missing for Primary role".to_string())?;
                primary.validate()?;
            }
            ReplicationRole::Replica => {
                let replica = self.replica_config.as_ref()
                    .ok_or_else(|| "Replica config missing for Replica role".to_string())?;
                replica.validate()?;
            }
        }
        Ok(())
    }
}

/// Configuration specific to primary node operation.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PrimaryConfig {
    /// Network address to bind for replica connections (e.g., "0.0.0.0:7233").
    pub listen_address: String,

    /// Maximum number of concurrent replica connections (default: 10).
    pub max_replicas: u32,

    /// Size of in-memory buffer for commit records (default: 100MB).
    pub replication_buffer_size: u64,
}

impl PrimaryConfig {
    /// Validate the primary configuration.
    pub fn validate(&self) -> Result<(), String> {
        // Validate listen address is a valid socket address
        if let Err(e) = self.listen_address.parse::<SocketAddr>() {
            // Allow hostname:port format (will be resolved later)
            if self.listen_address.split(':').count() != 2 {
                return Err(format!("Invalid listen_address format: {}", e));
            }
        }

        // Validate max_replicas is in reasonable range
        if !(1..=100).contains(&self.max_replicas) {
            return Err(format!(
                "max_replicas must be between 1 and 100, got {}",
                self.max_replicas
            ));
        }

        // Validate buffer size is reasonable (at least 1MB, at most 10GB)
        const MIN_BUFFER: u64 = 1024 * 1024;
        const MAX_BUFFER: u64 = 10 * 1024 * 1024 * 1024;
        if !(MIN_BUFFER..=MAX_BUFFER).contains(&self.replication_buffer_size) {
            return Err(format!(
                "replication_buffer_size must be between {} and {} bytes, got {}",
                MIN_BUFFER, MAX_BUFFER, self.replication_buffer_size
            ));
        }

        Ok(())
    }

    /// Calculate high watermark for backpressure (80% of buffer).
    pub const fn high_watermark(&self) -> u64 {
        self.replication_buffer_size * crate::replication::BUFFER_HIGH_WATERMARK_PCT / 100
    }

    /// Calculate low watermark for backpressure (60% of buffer).
    pub const fn low_watermark(&self) -> u64 {
        self.replication_buffer_size * crate::replication::BUFFER_LOW_WATERMARK_PCT / 100
    }
}

/// Configuration specific to replica node operation.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ReplicaConfig {
    /// Address of primary node to connect to (e.g., "primary.example.com:7233").
    pub primary_address: String,

    /// Target maximum replication lag in milliseconds (default: 100ms).
    pub replication_lag_target_ms: u64,

    /// Initial reconnect interval on disconnect in milliseconds (default: 1000ms).
    pub reconnect_interval_ms: u64,

    /// Whether to bootstrap from snapshot on first start (default: false).
    pub bootstrap_on_start: bool,
}

impl ReplicaConfig {
    /// Validate the replica configuration.
    pub fn validate(&self) -> Result<(), String> {
        // Validate primary address format
        if self.primary_address.is_empty() {
            return Err("primary_address cannot be empty".to_string());
        }

        // Check for port in address
        if !self.primary_address.contains(':') {
            return Err("primary_address must include port (e.g., 'primary.example.com:7233')".to_string());
        }

        // Validate lag targets (10ms to 60000ms)
        if !(10..=60000).contains(&self.replication_lag_target_ms) {
            return Err(format!(
                "replication_lag_target_ms must be between 10 and 60000, got {}",
                self.replication_lag_target_ms
            ));
        }

        // Validate reconnect interval (100ms to 60000ms)
        if !(100..=60000).contains(&self.reconnect_interval_ms) {
            return Err(format!(
                "reconnect_interval_ms must be between 100 and 60000, got {}",
                self.reconnect_interval_ms
            ));
        }

        Ok(())
    }

    /// Calculate exponential backoff delay for reconnection.
    ///
    /// Formula: delay = min(base * 2^attempt, max)
    pub fn backoff_delay(&self, attempt: u32) -> u64 {
        const MAX_BACKOFF_MS: u64 = 60000; // 60 seconds max
        let delay = self.reconnect_interval_ms * 2u64.pow(attempt.min(10)); // Cap exponent at 10
        delay.min(MAX_BACKOFF_MS)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_replication_role_methods() {
        assert!(ReplicationRole::Primary.is_primary());
        assert!(!ReplicationRole::Primary.is_replica());
        assert!(ReplicationRole::Replica.is_replica());
        assert!(!ReplicationRole::Replica.is_primary());
    }

    #[test]
    fn test_replication_config_primary() {
        let config = ReplicationConfig::primary("0.0.0.0:7233".to_string(), 10);
        assert!(config.role.is_primary());
        assert!(config.primary_config.is_some());
        assert!(config.replica_config.is_none());
        config.validate().unwrap();
    }

    #[test]
    fn test_replication_config_replica() {
        let config = ReplicationConfig::replica("primary.example.com:7233".to_string());
        assert!(config.role.is_replica());
        assert!(config.primary_config.is_none());
        assert!(config.replica_config.is_some());
        config.validate().unwrap();
    }

    #[test]
    fn test_primary_config_validate() {
        let valid = PrimaryConfig {
            listen_address: "0.0.0.0:7233".to_string(),
            max_replicas: 10,
            replication_buffer_size: 100 * 1024 * 1024,
        };
        assert!(valid.validate().is_ok());

        // Invalid max_replicas
        let invalid = PrimaryConfig {
            listen_address: "0.0.0.0:7233".to_string(),
            max_replicas: 0,
            replication_buffer_size: 100 * 1024 * 1024,
        };
        assert!(invalid.validate().is_err());

        // Invalid buffer size
        let invalid = PrimaryConfig {
            listen_address: "0.0.0.0:7233".to_string(),
            max_replicas: 10,
            replication_buffer_size: 1024, // Too small
        };
        assert!(invalid.validate().is_err());
    }

    #[test]
    fn test_primary_config_watermarks() {
        let config = PrimaryConfig {
            listen_address: "0.0.0.0:7233".to_string(),
            max_replicas: 10,
            replication_buffer_size: 1000,
        };

        let high = config.high_watermark();
        let low = config.low_watermark();

        assert_eq!(high, 800); // 80% of 1000
        assert_eq!(low, 600); // 60% of 1000
        assert!(high > low);
    }

    #[test]
    fn test_replica_config_validate() {
        let valid = ReplicaConfig {
            primary_address: "primary.example.com:7233".to_string(),
            replication_lag_target_ms: 100,
            reconnect_interval_ms: 1000,
            bootstrap_on_start: false,
        };
        assert!(valid.validate().is_ok());

        // Missing port
        let invalid = ReplicaConfig {
            primary_address: "primary.example.com".to_string(),
            replication_lag_target_ms: 100,
            reconnect_interval_ms: 1000,
            bootstrap_on_start: false,
        };
        assert!(invalid.validate().is_err());

        // Invalid lag target
        let invalid = ReplicaConfig {
            primary_address: "primary.example.com:7233".to_string(),
            replication_lag_target_ms: 5, // Too small
            reconnect_interval_ms: 1000,
            bootstrap_on_start: false,
        };
        assert!(invalid.validate().is_err());
    }

    #[test]
    fn test_replica_config_backoff() {
        let config = ReplicaConfig {
            primary_address: "primary.example.com:7233".to_string(),
            replication_lag_target_ms: 100,
            reconnect_interval_ms: 1000,
            bootstrap_on_start: false,
        };

        // Test exponential backoff
        assert_eq!(config.backoff_delay(0), 1000); // 1000 * 2^0
        assert_eq!(config.backoff_delay(1), 2000); // 1000 * 2^1
        assert_eq!(config.backoff_delay(2), 4000); // 1000 * 2^2
        assert_eq!(config.backoff_delay(3), 8000); // 1000 * 2^3

        // Test cap at max
        assert_eq!(config.backoff_delay(10), 60000); // Capped
        assert_eq!(config.backoff_delay(100), 60000); // Capped
    }

    #[test]
    fn test_replication_config_validate_missing_configs() {
        // Primary without primary_config
        let config = ReplicationConfig {
            role: ReplicationRole::Primary,
            primary_config: None,
            replica_config: None,
        };
        assert!(config.validate().is_err());

        // Replica without replica_config
        let config = ReplicationConfig {
            role: ReplicationRole::Replica,
            primary_config: None,
            replica_config: None,
        };
        assert!(config.validate().is_err());
    }
}
