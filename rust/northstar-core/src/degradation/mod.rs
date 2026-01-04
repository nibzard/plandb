//! Graceful degradation system for NorthstarDB
//!
//! This module provides automatic degradation and recovery under adverse conditions
//! including resource exhaustion, external service failures, and high load.

mod state;
mod monitor;
mod fallback;
mod circuit_breaker;
mod throttler;
mod policy;

pub use state::{
    DegradationLevel,
    DegradationTrigger,
    DegradationAction,
    DegradationState,
    DegradationPolicy,
    DegradationConfig,
    RecoveryCondition,
};
pub use monitor::{
    ResourceMonitor,
    ResourceSnapshot,
    ResourceThresholds,
    monitor_resources,
};
pub use fallback::{
    FallbackMode,
    FallbackManager,
    TransitionEvent,
    execute_degradation_actions,
};
pub use circuit_breaker::{
    CircuitState,
    CircuitBreaker,
    circuit_breaker_call,
    CircuitOpenError,
};
pub use throttler::{
    Throttler,
    throttler_acquire,
};
pub use policy::{
    evaluate_degradation_level,
    check_recovery_conditions,
    recover_to_full,
};
