//! Fallback mode management for degradation

use std::collections::{HashSet, VecDeque};
use std::sync::{Arc, RwLock};
use std::time::Instant;

use super::state::{DegradationAction, DegradationConfig, DegradationLevel, DegradationTrigger};
use std::sync::RwLock as StdRwLock;

/// Active fallback mode for specific subsystems
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum FallbackMode {
    /// Caching disabled, direct access only
    CacheDisabled,
    /// AI features disabled, basic operations only
    AiDisabled,
    /// Maintenance tasks paused
    BackgroundTasksPaused,
    /// Writes rate-limited
    WriteThrottled,
    /// Reads rate-limited
    ReadThrottled,
    /// Skip query optimization, use simple plans
    QueryOptimizationDisabled,
    /// Full table scan instead of index usage
    IndexSeekDisabled,
    /// Skip compression to save CPU
    CompressionDisabled,
}

impl FallbackMode {
    /// Get all fallback modes
    pub fn all() -> Vec<Self> {
        vec![
            Self::CacheDisabled,
            Self::AiDisabled,
            Self::BackgroundTasksPaused,
            Self::WriteThrottled,
            Self::ReadThrottled,
            Self::QueryOptimizationDisabled,
            Self::IndexSeekDisabled,
            Self::CompressionDisabled,
        ]
    }

    /// Check if this mode conflicts with another
    pub fn conflicts_with(&self, other: &Self) -> bool {
        matches!(
            (self, other),
            (Self::CacheDisabled, Self::CacheDisabled)
                | (Self::AiDisabled, Self::AiDisabled)
                | (Self::BackgroundTasksPaused, Self::BackgroundTasksPaused)
                | (Self::WriteThrottled, Self::WriteThrottled)
                | (Self::ReadThrottled, Self::ReadThrottled)
        )
    }
}

/// Records mode changes with timestamps
#[derive(Debug, Clone)]
pub struct TransitionEvent {
    /// Mode that changed
    pub mode: FallbackMode,
    /// True if activated, false if deactivated
    pub activated: bool,
    /// When transition occurred
    pub timestamp: Instant,
    /// What caused the transition
    pub trigger: DegradationTrigger,
}

impl TransitionEvent {
    /// Create a new transition event
    pub fn new(mode: FallbackMode, activated: bool, trigger: DegradationTrigger) -> Self {
        Self {
            mode,
            activated,
            timestamp: Instant::now(),
            trigger,
        }
    }
}

/// Manages active fallback modes and coordinates transitions
#[derive(Debug)]
pub struct FallbackManager {
    /// Currently active fallbacks
    pub active_modes: HashSet<FallbackMode>,
    /// Recent mode changes (max: 50 entries)
    pub transition_history: VecDeque<TransitionEvent>,
    /// Shared configuration
    pub config: Arc<DegradationConfig>,
    /// Maximum history size
    pub max_history_size: usize,
}

impl FallbackManager {
    /// Create a new fallback manager
    pub fn new(config: Arc<DegradationConfig>) -> Self {
        Self {
            active_modes: HashSet::new(),
            transition_history: VecDeque::with_capacity(50),
            config,
            max_history_size: 50,
        }
    }

    /// Activate a fallback mode
    pub fn activate(&mut self, mode: FallbackMode, trigger: DegradationTrigger) {
        if !self.active_modes.contains(&mode) {
            self.active_modes.insert(mode);
            self.record_transition(mode, true, trigger);
        }
    }

    /// Deactivate a fallback mode
    pub fn deactivate(&mut self, mode: FallbackMode, trigger: DegradationTrigger) {
        if self.active_modes.remove(&mode) {
            self.record_transition(mode, false, trigger);
        }
    }

    /// Check if a mode is active
    pub fn is_active(&self, mode: FallbackMode) -> bool {
        self.active_modes.contains(&mode)
    }

    /// Get all active modes
    pub fn active_modes_list(&self) -> Vec<FallbackMode> {
        self.active_modes.iter().copied().collect()
    }

    /// Deactivate all modes
    pub fn deactivate_all(&mut self, trigger: DegradationTrigger) {
        let modes: Vec<FallbackMode> = self.active_modes.iter().copied().collect();
        for mode in modes {
            self.deactivate(mode, trigger.clone());
        }
    }

    /// Record a transition event
    fn record_transition(&mut self, mode: FallbackMode, activated: bool, trigger: DegradationTrigger) {
        let event = TransitionEvent::new(mode, activated, trigger);

        if self.transition_history.len() >= self.max_history_size {
            self.transition_history.pop_front();
        }

        self.transition_history.push_back(event);
    }

    /// Get transition history
    pub fn history(&self) -> Vec<TransitionEvent> {
        self.transition_history.iter().cloned().collect()
    }

    /// Get count of transitions for a specific mode
    pub fn transition_count(&self, mode: FallbackMode) -> usize {
        self.transition_history
            .iter()
            .filter(|e| e.mode == mode)
            .count()
    }
}

/// Execute degradation actions by activating appropriate fallback modes
///
/// This is a placeholder implementation. The actual implementation would integrate
/// with the database components to execute the actions.
pub fn execute_degradation_actions(
    level: DegradationLevel,
    actions: Vec<DegradationAction>,
    fallback_manager: Arc<StdRwLock<FallbackManager>>,
) -> Result<(), String> {
    // This would integrate with Db, cache, AI, etc.
    // For now, we'll just map actions to fallback modes

    let mut manager = fallback_manager
        .write()
        .map_err(|e| format!("Failed to lock fallback manager: {}", e))?;

    for action in &actions {
        match action {
            DegradationAction::ReduceCacheSize => {
                manager.activate(FallbackMode::CacheDisabled, DegradationTrigger::MemoryPressure);
            }
            DegradationAction::DisableBackgroundTasks => {
                manager.activate(
                    FallbackMode::BackgroundTasksPaused,
                    DegradationTrigger::CpuSaturation,
                );
            }
            DegradationAction::ThrottleWrites => {
                manager.activate(FallbackMode::WriteThrottled, DegradationTrigger::WriteLatencyHigh);
            }
            DegradationAction::RejectNonCriticalQueries => {
                manager.activate(
                    FallbackMode::QueryOptimizationDisabled,
                    DegradationTrigger::CpuSaturation,
                );
            }
            DegradationAction::SwitchToReadOnly => {
                // This is a special case - no specific fallback mode
                // Would set read-only flag on database
            }
            DegradationAction::FlushCaches => {
                manager.activate(FallbackMode::CacheDisabled, DegradationTrigger::MemoryPressure);
            }
            DegradationAction::ReduceConnectionPool => {
                // No specific fallback mode - would adjust pool size
            }
            DegradationAction::DisableAiFeatures => {
                manager.activate(
                    FallbackMode::AiDisabled,
                    DegradationTrigger::ExternalServiceUnavailable,
                );
            }
            DegradationAction::EnableFastPath => {
                manager.activate(
                    FallbackMode::CompressionDisabled,
                    DegradationTrigger::CpuSaturation,
                );
            }
        }
    }

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_fallback_mode_conflicts() {
        assert!(FallbackMode::CacheDisabled.conflicts_with(&FallbackMode::CacheDisabled));
        assert!(!FallbackMode::CacheDisabled.conflicts_with(&FallbackMode::AiDisabled));
    }

    #[test]
    fn test_fallback_manager_activate() {
        let config = Arc::new(DegradationConfig::default());
        let mut manager = FallbackManager::new(config);

        assert!(!manager.is_active(FallbackMode::CacheDisabled));

        manager.activate(
            FallbackMode::CacheDisabled,
            DegradationTrigger::MemoryPressure,
        );

        assert!(manager.is_active(FallbackMode::CacheDisabled));
        assert_eq!(manager.transition_history.len(), 1);
    }

    #[test]
    fn test_fallback_manager_deactivate() {
        let config = Arc::new(DegradationConfig::default());
        let mut manager = FallbackManager::new(config);

        manager.activate(
            FallbackMode::CacheDisabled,
            DegradationTrigger::MemoryPressure,
        );
        assert!(manager.is_active(FallbackMode::CacheDisabled));

        manager.deactivate(
            FallbackMode::CacheDisabled,
            DegradationTrigger::MemoryPressure,
        );
        assert!(!manager.is_active(FallbackMode::CacheDisabled));
        assert_eq!(manager.transition_history.len(), 2);
    }

    #[test]
    fn test_fallback_manager_history_limit() {
        let config = Arc::new(DegradationConfig::default());
        let mut manager = FallbackManager::new(config);

        // Add more transitions than max_history_size
        for i in 0..100 {
            if i % 2 == 0 {
                manager.activate(
                    FallbackMode::CacheDisabled,
                    DegradationTrigger::MemoryPressure,
                );
            } else {
                manager.deactivate(
                    FallbackMode::CacheDisabled,
                    DegradationTrigger::MemoryPressure,
                );
            }
        }

        // History should be bounded
        assert_eq!(manager.transition_history.len(), 50);
    }

    #[test]
    fn test_fallback_manager_deactivate_all() {
        let config = Arc::new(DegradationConfig::default());
        let mut manager = FallbackManager::new(config);

        manager.activate(FallbackMode::CacheDisabled, DegradationTrigger::MemoryPressure);
        manager.activate(FallbackMode::AiDisabled, DegradationTrigger::ExternalServiceUnavailable);
        manager.activate(
            FallbackMode::BackgroundTasksPaused,
            DegradationTrigger::CpuSaturation,
        );

        assert_eq!(manager.active_modes_list().len(), 3);

        manager.deactivate_all(DegradationTrigger::ManualOverride);

        assert_eq!(manager.active_modes_list().len(), 0);
    }

    #[test]
    fn test_fallback_manager_transition_count() {
        let config = Arc::new(DegradationConfig::default());
        let mut manager = FallbackManager::new(config);

        for _ in 0..5 {
            manager.activate(
                FallbackMode::CacheDisabled,
                DegradationTrigger::MemoryPressure,
            );
            manager.deactivate(
                FallbackMode::CacheDisabled,
                DegradationTrigger::MemoryPressure,
            );
        }

        assert_eq!(manager.transition_count(FallbackMode::CacheDisabled), 10);
    }

    #[test]
    fn test_transition_event_new() {
        let event = TransitionEvent::new(
            FallbackMode::CacheDisabled,
            true,
            DegradationTrigger::MemoryPressure,
        );

        assert_eq!(event.mode, FallbackMode::CacheDisabled);
        assert!(event.activated);
        assert!(matches!(
            event.trigger,
            DegradationTrigger::MemoryPressure
        ));
    }

    #[test]
    fn test_execute_degradation_actions() {
        let config = Arc::new(DegradationConfig::default());
        let manager = Arc::new(RwLock::new(FallbackManager::new(config)));

        let actions = vec![
            DegradationAction::ReduceCacheSize,
            DegradationAction::DisableAiFeatures,
        ];

        let result = execute_degradation_actions(
            DegradationLevel::Reduced,
            actions,
            Arc::clone(&manager),
        );

        assert!(result.is_ok());

        let manager_read = manager.read().unwrap();
        assert!(manager_read.is_active(FallbackMode::CacheDisabled));
        assert!(manager_read.is_active(FallbackMode::AiDisabled));
    }
}
