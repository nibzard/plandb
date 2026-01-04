//! Policy evaluation and recovery logic

use std::sync::{Arc, RwLock};
use std::time::Duration;

use super::state::{
    DegradationLevel, DegradationPolicy, DegradationState, DegradationConfig, DegradationTrigger,
};
use super::monitor::ResourceMonitor;
use super::fallback::FallbackManager;
use std::sync::RwLock as StdRwLock;

/// Determine appropriate degradation level based on active triggers
pub fn evaluate_degradation_level(
    state: Arc<RwLock<DegradationState>>,
    triggers: Vec<DegradationTrigger>,
    config: Arc<DegradationConfig>,
) -> DegradationLevel {
    let current_state = state.read().unwrap();
    let current_level = current_state.current_level;
    let time_in_level = current_state.time_in_level();
    drop(current_state);

    // Check if any triggers present
    if triggers.is_empty() {
        return DegradationLevel::Full;
    }

    // Evaluate triggers for emergency conditions
    for trigger in &triggers {
        match trigger {
            DegradationTrigger::MemoryPressure => {
                // Emergency if <5% memory
                // This would need actual resource data - placeholder
            }
            DegradationTrigger::DiskSpaceLow => {
                // Emergency if <2% disk
                // This would need actual resource data - placeholder
            }
            _ => {}
        }
    }

    // Check for minimal triggers
    let has_minimal_trigger = triggers.iter().any(|t| {
        matches!(
            t,
            DegradationTrigger::MemoryPressure
                | DegradationTrigger::CpuSaturation
                | DegradationTrigger::ConnectionPoolExhausted
        )
    });

    if has_minimal_trigger {
        let proposed_level = DegradationLevel::Minimal;

        // Enforce min_duration to prevent flapping
        if let Some(policy) = config.policy_for_level(proposed_level) {
            if time_in_level < policy.min_duration && current_level > proposed_level {
                // Not enough time in current level, stay where we are
                return current_level;
            }
        }

        return proposed_level;
    }

    // Any other trigger results in Reduced level
    let proposed_level = DegradationLevel::Reduced;

    if let Some(policy) = config.policy_for_level(proposed_level) {
        if time_in_level < policy.min_duration && current_level > proposed_level {
            return current_level;
        }
    }

    proposed_level
}

/// Check if recovery conditions are met for current degradation level
pub fn check_recovery_conditions(
    state: Arc<RwLock<DegradationState>>,
    monitor: Arc<ResourceMonitor>,
    config: Arc<DegradationConfig>,
) -> bool {
    let current_state = state.read().unwrap();
    let current_level = current_state.current_level;

    if current_level == DegradationLevel::Full {
        return true;
    }

    // Get policy for current level
    let policy = match config.policy_for_level(current_level) {
        Some(p) => p,
        None => return false,
    };

    // Check minimum duration
    if current_state.time_in_level() < policy.min_duration {
        return false;
    }

    // Check all recovery conditions
    let snapshot = match monitor.latest_snapshot() {
        Some(s) => s,
        None => return false,
    };

    for condition in &policy.recovery_conditions {
        let metric_value = match condition.metric_name.as_str() {
            "memory_free_percent" => snapshot.memory_free_percent,
            "disk_free_percent" => snapshot.disk_free_percent,
            "cpu_usage_percent" => snapshot.cpu_usage_percent,
            "cache_hit_rate" => snapshot.cache_hit_rate * 100.0,
            "write_latency_p99_ms" => snapshot.write_latency_p99.as_millis() as f64,
            "read_latency_p99_ms" => snapshot.read_latency_p99.as_millis() as f64,
            _ => continue,
        };

        // Check if condition is met
        let condition_met = match condition.metric_name.as_str() {
            "memory_free_percent" | "disk_free_percent" | "cache_hit_rate" => {
                metric_value >= condition.threshold
            }
            "cpu_usage_percent" | "write_latency_p99_ms" | "read_latency_p99_ms" => {
                metric_value <= condition.threshold
            }
            _ => true,
        };

        if !condition_met {
            return false;
        }
    }

    true
}

/// Execute recovery actions to return to full operation
pub fn recover_to_full(
    state: Arc<RwLock<DegradationState>>,
    fallback_manager: Arc<StdRwLock<FallbackManager>>,
) -> Result<(), String> {
    let mut state_write = state.write().map_err(|e| format!("Failed to lock state: {}", e))?;

    let current_level = state_write.current_level;

    if current_level == DegradationLevel::Full {
        return Ok(());
    }

    // Deactivate all fallback modes
    let mut manager = fallback_manager
        .write()
        .map_err(|e| format!("Failed to lock fallback manager: {}", e))?;

    manager.deactivate_all(DegradationTrigger::ManualOverride);

    // Update state
    state_write.transition_to(DegradationLevel::Full, vec![]);
    state_write.recovery_attempt_count = 0;

    Ok(())
}

/// Attempt recovery from current degradation level
pub fn attempt_recovery(
    state: Arc<RwLock<DegradationState>>,
    monitor: Arc<ResourceMonitor>,
    fallback_manager: Arc<StdRwLock<FallbackManager>>,
    config: Arc<DegradationConfig>,
) -> Result<bool, String> {
    // Check if recovery conditions are met
    if !check_recovery_conditions(Arc::clone(&state), Arc::clone(&monitor), Arc::clone(&config)) {
        return Ok(false);
    }

    // Perform recovery
    recover_to_full(Arc::clone(&state), Arc::clone(&fallback_manager))?;

    Ok(true)
}

/// Get recommended actions for a degradation level
pub fn get_actions_for_level(
    level: DegradationLevel,
    config: Arc<DegradationConfig>,
) -> Vec<super::state::DegradationAction> {
    if let Some(policy) = config.policy_for_level(level) {
        policy.actions.clone()
    } else {
        Vec::new()
    }
}

/// Create default degradation policies
pub fn create_default_policies() -> Vec<DegradationPolicy> {
    vec![
        // Reduced level policy
        DegradationPolicy::new(DegradationLevel::Reduced, Duration::from_secs(30))
            .with_trigger(DegradationTrigger::MemoryPressure)
            .with_trigger(DegradationTrigger::DiskSpaceLow)
            .with_trigger(DegradationTrigger::CpuSaturation)
            .with_trigger(DegradationTrigger::ConnectionPoolExhausted)
            .with_trigger(DegradationTrigger::CacheEvictionRateHigh)
            .with_trigger(DegradationTrigger::WriteLatencyHigh)
            .with_trigger(DegradationTrigger::ReadLatencyHigh)
            .with_action(super::state::DegradationAction::ReduceCacheSize)
            .with_action(super::state::DegradationAction::ThrottleWrites)
            .with_recovery_condition(super::state::RecoveryCondition::new(
                "memory_free_percent",
                20.0,
                Duration::from_secs(60),
            ))
            .with_recovery_condition(super::state::RecoveryCondition::new(
                "cpu_usage_percent",
                75.0,
                Duration::from_secs(60),
            )),
        // Minimal level policy
        DegradationPolicy::new(DegradationLevel::Minimal, Duration::from_secs(60))
            .with_trigger(DegradationTrigger::MemoryPressure)
            .with_trigger(DegradationTrigger::CpuSaturation)
            .with_action(super::state::DegradationAction::FlushCaches)
            .with_action(super::state::DegradationAction::DisableBackgroundTasks)
            .with_action(super::state::DegradationAction::DisableAiFeatures)
            .with_action(super::state::DegradationAction::RejectNonCriticalQueries)
            .with_recovery_condition(super::state::RecoveryCondition::new(
                "memory_free_percent",
                15.0,
                Duration::from_secs(120),
            )),
        // Maintenance level policy
        DegradationPolicy::new(DegradationLevel::Maintenance, Duration::from_secs(30))
            .with_action(super::state::DegradationAction::SwitchToReadOnly)
            .with_action(super::state::DegradationAction::DisableBackgroundTasks)
            .with_recovery_condition(super::state::RecoveryCondition::new(
                "disk_free_percent",
                10.0,
                Duration::from_secs(60),
            )),
    ]
}

#[cfg(test)]
mod tests {
    use super::*;
    use super::super::state::DegradationAction;
    use std::sync::Arc;

    #[test]
    fn test_evaluate_degradation_level_no_triggers() {
        let state = Arc::new(RwLock::new(DegradationState::new()));
        let config = Arc::new(DegradationConfig::default());

        let level = evaluate_degradation_level(state, vec![], config);

        assert_eq!(level, DegradationLevel::Full);
    }

    #[test]
    fn test_evaluate_degradation_level_with_triggers() {
        let state = Arc::new(RwLock::new(DegradationState::new()));
        let config = Arc::new(DegradationConfig::default());

        let triggers = vec![DegradationTrigger::WriteLatencyHigh];

        let level = evaluate_degradation_level(state, triggers, config);

        assert_eq!(level, DegradationLevel::Reduced);
    }

    #[test]
    fn test_evaluate_degradation_level_min_duration() {
        let mut state_obj = DegradationState::new();
        state_obj.transition_to(
            DegradationLevel::Reduced,
            vec![DegradationTrigger::WriteLatencyHigh],
        );

        let state = Arc::new(RwLock::new(state_obj));
        let config = Arc::new(DegradationConfig::default());

        // With recent transition, should stay at Reduced
        let triggers = vec![DegradationTrigger::MemoryPressure];
        let level = evaluate_degradation_level(state, triggers, config);

        assert_eq!(level, DegradationLevel::Reduced);
    }

    #[test]
    fn test_get_actions_for_level() {
        let mut config = DegradationConfig::default();
        let policy = DegradationPolicy::new(DegradationLevel::Reduced, Duration::from_secs(30))
            .with_action(DegradationAction::ReduceCacheSize)
            .with_action(DegradationAction::ThrottleWrites);

        config.policies.push(policy);
        let config = Arc::new(config);

        let actions = get_actions_for_level(DegradationLevel::Reduced, config);

        assert_eq!(actions.len(), 2);
    }

    #[test]
    fn test_create_default_policies() {
        let policies = create_default_policies();

        assert!(!policies.is_empty());
        assert!(policies.iter().any(|p| p.level == DegradationLevel::Reduced));
        assert!(policies.iter().any(|p| p.level == DegradationLevel::Minimal));
        assert!(policies.iter().any(|p| p.level == DegradationLevel::Maintenance));
    }

    #[test]
    fn test_recover_to_full() {
        let mut state_obj = DegradationState::new();
        state_obj.transition_to(
            DegradationLevel::Reduced,
            vec![DegradationTrigger::MemoryPressure],
        );

        let state = Arc::new(RwLock::new(state_obj));
        let config = Arc::new(DegradationConfig::default());
        let fallback = Arc::new(StdRwLock::new(FallbackManager::new(Arc::clone(&config))));

        let result = recover_to_full(Arc::clone(&state), Arc::clone(&fallback));

        assert!(result.is_ok());

        let state_read = state.read().unwrap();
        assert_eq!(state_read.current_level, DegradationLevel::Full);
    }

    #[test]
    fn test_recover_to_full_already_full() {
        let state = Arc::new(RwLock::new(DegradationState::new()));
        let config = Arc::new(DegradationConfig::default());
        let fallback = Arc::new(StdRwLock::new(FallbackManager::new(Arc::clone(&config))));

        let result = recover_to_full(state, fallback);

        assert!(result.is_ok());
    }

    #[test]
    fn test_attempt_recovery_conditions_not_met() {
        let state = Arc::new(RwLock::new(DegradationState::new()));
        let config = Arc::new(DegradationConfig::default());
        let monitor = Arc::new(ResourceMonitor::new(Arc::clone(&config)));
        let fallback = Arc::new(StdRwLock::new(FallbackManager::new(Arc::clone(&config))));

        // No monitor history, conditions can't be met
        let result = attempt_recovery(state, monitor, fallback, config);

        assert!(result.is_ok());
        assert!(!result.unwrap());
    }
}
