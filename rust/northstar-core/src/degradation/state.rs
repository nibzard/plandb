//! Degradation state and level management

use std::sync::{Arc, RwLock};
use std::time::{Duration, Instant};
use serde::{Deserialize, Serialize};

/// Current operating level of the database system
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
pub enum DegradationLevel {
    /// All functionality available, normal operation
    Full,
    /// Some features limited but core operations work
    Reduced,
    /// Critical operations only, best-effort service
    Minimal,
    /// Read-only mode, writes rejected
    Maintenance,
    /// Safe shutdown in progress
    Emergency,
}

impl DegradationLevel {
    /// Returns true if this level allows write operations
    pub fn allows_writes(&self) -> bool {
        matches!(self, Self::Full | Self::Reduced | Self::Minimal)
    }

    /// Returns true if this level allows AI features
    pub fn allows_ai(&self) -> bool {
        matches!(self, Self::Full | Self::Reduced)
    }

    /// Returns true if this level allows background tasks
    pub fn allows_background_tasks(&self) -> bool {
        matches!(self, Self::Full | Self::Reduced)
    }
}

impl Default for DegradationLevel {
    fn default() -> Self {
        Self::Full
    }
}

/// Event or condition that triggers degradation mode change
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Hash)]
pub enum DegradationTrigger {
    /// Available memory below threshold
    MemoryPressure,
    /// Disk space below threshold
    DiskSpaceLow,
    /// CPU usage sustained above threshold
    CpuSaturation,
    /// No available connections
    ConnectionPoolExhausted,
    /// Cache evictions exceed insertions
    CacheEvictionRateHigh,
    /// Write latency above threshold
    WriteLatencyHigh,
    /// Read latency above threshold
    ReadLatencyHigh,
    /// AI plugin or external service down
    ExternalServiceUnavailable,
    /// Administrator-triggered degradation
    ManualOverride,
}

/// Action taken when entering a degradation level
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Hash)]
pub enum DegradationAction {
    /// Shrink cache to free memory
    ReduceCacheSize,
    /// Pause maintenance, compaction, statistics
    DisableBackgroundTasks,
    /// Rate-limit write operations
    ThrottleWrites,
    /// Return error for non-essential reads
    RejectNonCriticalQueries,
    /// Reject all write operations
    SwitchToReadOnly,
    /// Clear all caches to free memory
    FlushCaches,
    /// Close idle connections
    ReduceConnectionPool,
    /// Turn off AI plugin system
    DisableAiFeatures,
    /// Use optimized code paths bypassing safety checks
    EnableFastPath,
}

/// Condition that must be met to recover from a degradation level
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RecoveryCondition {
    /// Metric to monitor (e.g., "memory_free_percent")
    pub metric_name: String,
    /// Value that indicates recovery
    pub threshold: f64,
    /// How long condition must hold
    pub duration: Duration,
}

impl RecoveryCondition {
    /// Create a new recovery condition
    pub fn new(metric_name: impl Into<String>, threshold: f64, duration: Duration) -> Self {
        Self {
            metric_name: metric_name.into(),
            threshold,
            duration,
        }
    }
}

/// Policy defining triggers and actions for degradation levels
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DegradationPolicy {
    /// Policy level
    pub level: DegradationLevel,
    /// Conditions that trigger this level
    pub triggers: Vec<DegradationTrigger>,
    /// Actions to take when entering this level
    pub actions: Vec<DegradationAction>,
    /// Conditions to exit this level
    pub recovery_conditions: Vec<RecoveryCondition>,
    /// Minimum time to stay in level (prevents flapping)
    pub min_duration: Duration,
    /// Maximum time before forced action
    pub max_duration: Option<Duration>,
}

impl DegradationPolicy {
    /// Create a new degradation policy
    pub fn new(level: DegradationLevel, min_duration: Duration) -> Self {
        Self {
            level,
            triggers: Vec::new(),
            actions: Vec::new(),
            recovery_conditions: Vec::new(),
            min_duration,
            max_duration: None,
        }
    }

    /// Add a trigger to the policy
    pub fn with_trigger(mut self, trigger: DegradationTrigger) -> Self {
        self.triggers.push(trigger);
        self
    }

    /// Add an action to the policy
    pub fn with_action(mut self, action: DegradationAction) -> Self {
        self.actions.push(action);
        self
    }

    /// Add a recovery condition to the policy
    pub fn with_recovery_condition(mut self, condition: RecoveryCondition) -> Self {
        self.recovery_conditions.push(condition);
        self
    }

    /// Set max duration
    pub fn with_max_duration(mut self, duration: Duration) -> Self {
        self.max_duration = Some(duration);
        self
    }
}

/// Configuration for degradation behavior
#[derive(Debug, Clone)]
pub struct DegradationConfig {
    /// Whether degradation is enabled
    pub enabled: bool,
    /// Ordered policies for each level
    pub policies: Vec<DegradationPolicy>,
    /// Resource monitoring interval
    pub monitoring_interval: Duration,
    /// Max level changes before marking unstable
    pub flap_threshold: u32,
    /// Whether to auto-recover
    pub auto_recovery: bool,
    /// How often to check recovery
    pub recovery_check_interval: Duration,
    /// Max time in emergency before forced shutdown
    pub emergency_shutdown_timeout: Duration,
}

impl Default for DegradationConfig {
    fn default() -> Self {
        Self {
            enabled: true,
            policies: Vec::new(),
            monitoring_interval: Duration::from_secs(5),
            flap_threshold: 5,
            auto_recovery: true,
            recovery_check_interval: Duration::from_secs(30),
            emergency_shutdown_timeout: Duration::from_secs(60),
        }
    }
}

impl DegradationConfig {
    /// Create a new degradation config
    pub fn new() -> Self {
        Self::default()
    }

    /// Add a policy to the config
    pub fn with_policy(mut self, policy: DegradationPolicy) -> Self {
        self.policies.push(policy);
        self
    }

    /// Get policy for a given level
    pub fn policy_for_level(&self, level: DegradationLevel) -> Option<&DegradationPolicy> {
        self.policies.iter().find(|p| p.level == level)
    }
}

/// Current state of the degradation system
#[derive(Debug)]
pub struct DegradationState {
    /// Current operating level
    pub current_level: DegradationLevel,
    /// Previous level (for recovery tracking)
    pub previous_level: DegradationLevel,
    /// When current level was entered
    pub level_since: Instant,
    /// Triggers that caused current level
    pub active_triggers: Vec<DegradationTrigger>,
    /// Actions currently in effect
    pub active_actions: Vec<DegradationAction>,
    /// Number of recovery attempts made
    pub recovery_attempt_count: u32,
    /// When last level change occurred
    pub last_transition: Instant,
    /// Number of rapid level changes (indicates instability)
    pub flap_count: u32,
}

impl Default for DegradationState {
    fn default() -> Self {
        let now = Instant::now();
        Self {
            current_level: DegradationLevel::Full,
            previous_level: DegradationLevel::Full,
            level_since: now,
            active_triggers: Vec::new(),
            active_actions: Vec::new(),
            recovery_attempt_count: 0,
            last_transition: now,
            flap_count: 0,
        }
    }
}

impl DegradationState {
    /// Create a new degradation state
    pub fn new() -> Self {
        Self::default()
    }

    /// Transition to a new degradation level
    pub fn transition_to(&mut self, new_level: DegradationLevel, triggers: Vec<DegradationTrigger>) {
        let now = Instant::now();

        // Check for flapping (transition before min_duration)
        let elapsed = now.duration_since(self.level_since);
        if elapsed < Duration::from_secs(30) {
            self.flap_count += 1;
        }

        self.previous_level = self.current_level;
        self.current_level = new_level;
        self.level_since = now;
        self.last_transition = now;
        self.active_triggers = triggers;
    }

    /// Get the duration since entering the current level
    pub fn time_in_level(&self) -> Duration {
        self.level_since.elapsed()
    }

    /// Check if the state is unstable (too many flaps)
    pub fn is_unstable(&self, flap_threshold: u32) -> bool {
        self.flap_count >= flap_threshold
    }

    /// Increment recovery attempt count
    pub fn increment_recovery_attempts(&mut self) {
        self.recovery_attempt_count += 1;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_degradation_level_write_permissions() {
        assert!(DegradationLevel::Full.allows_writes());
        assert!(DegradationLevel::Reduced.allows_writes());
        assert!(DegradationLevel::Minimal.allows_writes());
        assert!(!DegradationLevel::Maintenance.allows_writes());
        assert!(!DegradationLevel::Emergency.allows_writes());
    }

    #[test]
    fn test_degradation_level_ai_permissions() {
        assert!(DegradationLevel::Full.allows_ai());
        assert!(DegradationLevel::Reduced.allows_ai());
        assert!(!DegradationLevel::Minimal.allows_ai());
        assert!(!DegradationLevel::Maintenance.allows_ai());
        assert!(!DegradationLevel::Emergency.allows_ai());
    }

    #[test]
    fn test_degradation_state_transition() {
        let mut state = DegradationState::new();
        assert_eq!(state.current_level, DegradationLevel::Full);
        assert_eq!(state.flap_count, 0);

        state.transition_to(
            DegradationLevel::Reduced,
            vec![DegradationTrigger::MemoryPressure],
        );

        assert_eq!(state.current_level, DegradationLevel::Reduced);
        assert_eq!(state.previous_level, DegradationLevel::Full);
        assert_eq!(state.active_triggers.len(), 1);
    }

    #[test]
    fn test_degradation_state_flapping() {
        let mut state = DegradationState::new();

        // Rapid transitions should increase flap count
        for _ in 0..3 {
            state.transition_to(
                DegradationLevel::Reduced,
                vec![DegradationTrigger::MemoryPressure],
            );
        }

        assert!(state.flap_count > 0);
    }

    #[test]
    fn test_degradation_policy_builder() {
        let policy = DegradationPolicy::new(DegradationLevel::Reduced, Duration::from_secs(30))
            .with_trigger(DegradationTrigger::MemoryPressure)
            .with_action(DegradationAction::ReduceCacheSize)
            .with_recovery_condition(RecoveryCondition::new(
                "memory_free_percent",
                20.0,
                Duration::from_secs(60),
            ));

        assert_eq!(policy.level, DegradationLevel::Reduced);
        assert_eq!(policy.triggers.len(), 1);
        assert_eq!(policy.actions.len(), 1);
        assert_eq!(policy.recovery_conditions.len(), 1);
    }

    #[test]
    fn test_recovery_condition_new() {
        let condition = RecoveryCondition::new("memory_free_percent", 20.0, Duration::from_secs(60));
        assert_eq!(condition.metric_name, "memory_free_percent");
        assert_eq!(condition.threshold, 20.0);
        assert_eq!(condition.duration, Duration::from_secs(60));
    }

    #[test]
    fn test_degradation_config_default() {
        let config = DegradationConfig::default();
        assert!(config.enabled);
        assert_eq!(config.monitoring_interval, Duration::from_secs(5));
        assert_eq!(config.flap_threshold, 5);
        assert!(config.auto_recovery);
        assert_eq!(config.recovery_check_interval, Duration::from_secs(30));
        assert_eq!(config.emergency_shutdown_timeout, Duration::from_secs(60));
    }
}
