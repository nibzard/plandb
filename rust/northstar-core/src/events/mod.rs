//! AI Intelligence Layer - Event System
//!
//! Provides typed events for AI agent tracking, code review, observability, and debugging.
//! Events are versioned, time-travel-compatible, and logically separate from the hot
//! database commit path to avoid performance impact on core operations.

pub mod types;
pub mod storage;

// Re-exports for convenience
pub use types::{
    EventType, EventVisibility, EventHeader,
    AgentSessionStarted, AgentOperation, AgentSessionEnded,
    ReviewNote, ReviewSummary,
    PerfSample, PerfRegression, TimeWindow, CorrelationHints,
    DebugSession, DebugSnapshot, Breakpoint, DebugReferences,
    VcsCommit, VcsBranch,
    EventFilter, EventResult,
    MAX_EVENT_PAYLOAD_SIZE,
};

pub use storage::{
    EventStore, EventStoreConfig,
    EventIndexEntry,
};
