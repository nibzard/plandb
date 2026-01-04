//! Event types for AI Intelligence Layer.
//!
//! Defines typed events for AI agent tracking, code review, observability, and debugging.

use std::collections::HashMap;
use crate::error::{ValidationError, Result};

/// Maximum size for event payloads (1 MB)
pub const MAX_EVENT_PAYLOAD_SIZE: u32 = 1_048_576;

/// Enumeration of all event types in the system
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
#[repr(u16)]
#[non_exhaustive]
pub enum EventType {
    /// Agent session initialization event
    AgentSessionStarted = 0x1000,
    /// Agent session termination event
    AgentSessionEnded = 0x1001,
    /// Individual operation within a session
    AgentOperation = 0x1002,
    /// Human or AI-generated review note
    ReviewNote = 0x2000,
    /// Generated summary of reviews
    ReviewSummary = 0x2001,
    /// Performance metric sample point
    PerfSample = 0x3000,
    /// Detected performance regression
    PerfRegression = 0x3001,
    /// Debugging session event
    DebugSession = 0x4000,
    /// Debug state snapshot
    DebugSnapshot = 0x4001,
    /// Version control commit event
    VcsCommit = 0x5000,
    /// Branch operation event
    VcsBranch = 0x5001,
}

impl EventType {
    /// Returns the category of this event type
    pub fn category(&self) -> u8 {
        (*self as u16 >> 12) as u8
    }

    /// Creates EventType from raw u16
    pub fn from_raw(value: u16) -> Option<Self> {
        match value {
            0x1000 => Some(Self::AgentSessionStarted),
            0x1001 => Some(Self::AgentSessionEnded),
            0x1002 => Some(Self::AgentOperation),
            0x2000 => Some(Self::ReviewNote),
            0x2001 => Some(Self::ReviewSummary),
            0x3000 => Some(Self::PerfSample),
            0x3001 => Some(Self::PerfRegression),
            0x4000 => Some(Self::DebugSession),
            0x4001 => Some(Self::DebugSnapshot),
            0x5000 => Some(Self::VcsCommit),
            0x5001 => Some(Self::VcsBranch),
            _ => None,
        }
    }
}

/// Access control level for events
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
#[repr(u8)]
pub enum EventVisibility {
    /// Visible only to the creating agent
    Private = 0,
    /// Shared within team/context
    Team = 1,
    /// Publicly visible
    Public = 2,
}

impl EventVisibility {
    /// Creates EventVisibility from raw u8
    pub fn from_raw(value: u8) -> Option<Self> {
        match value {
            0 => Some(Self::Private),
            1 => Some(Self::Team),
            2 => Some(Self::Public),
            _ => None,
        }
    }
}

/// Metadata header for all events
#[derive(Debug, Clone, PartialEq, Eq)]
#[repr(C)]
pub struct EventHeader {
    /// Unique monotonically increasing event identifier
    pub event_id: u64,
    /// Type identifier for this event
    pub event_type: EventType,
    /// Unix nanosecond timestamp
    pub timestamp: i64,
    /// Agent or human identifier who created this event
    pub actor_id: u64,
    /// Optional session identifier for grouping
    pub session_id: Option<u64>,
    /// Access control level
    pub visibility: EventVisibility,
    /// Size of payload in bytes
    pub payload_len: u32,
}

impl EventHeader {
    /// Size of EventHeader in bytes (31 bytes with padding)
    pub const SIZE: usize = 31;

    /// Validates event header constraints
    pub fn validate(&self) -> Result<()> {
        if self.payload_len > MAX_EVENT_PAYLOAD_SIZE {
            return Err(ValidationError::PayloadLengthInvalid {
                len: self.payload_len,
                max: MAX_EVENT_PAYLOAD_SIZE,
            }.into());
        }
        Ok(())
    }

    /// Creates a new EventHeader
    pub fn new(
        event_type: EventType,
        timestamp: i64,
        actor_id: u64,
        session_id: Option<u64>,
        visibility: EventVisibility,
        payload_len: u32,
    ) -> Self {
        Self {
            event_id: 0, // Assigned by storage
            event_type,
            timestamp,
            actor_id,
            session_id,
            visibility,
            payload_len,
        }
    }
}

/// Payload for agent session initialization
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AgentSessionStarted {
    /// Unique identifier for the agent
    pub agent_id: u64,
    /// Version string of the agent software
    pub agent_version: String,
    /// Human-readable purpose of this session
    pub session_purpose: String,
    /// Additional key-value metadata
    pub metadata: HashMap<String, String>,
}

impl AgentSessionStarted {
    /// Validates the event payload
    pub fn validate(&self) -> Result<()> {
        if self.agent_version.is_empty() {
            return Err(ValidationError::Generic("agent_version cannot be empty".into()).into());
        }
        if self.session_purpose.is_empty() {
            return Err(ValidationError::Generic("session_purpose cannot be empty".into()).into());
        }
        for (key, _) in &self.metadata {
            if key.is_empty() {
                return Err(ValidationError::Generic("metadata keys cannot be empty".into()).into());
            }
        }
        Ok(())
    }
}

/// Payload for individual agent operations
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AgentOperation {
    /// Type of operation (e.g., "commit", "query", "analyze")
    pub operation_type: String,
    /// Unique identifier for this operation
    pub operation_id: u64,
    /// Type of target (e.g., "file", "symbol", "cartridge")
    pub target_type: String,
    /// Identifier of the target (path, symbol name, etc.)
    pub target_id: String,
    /// Operation status (e.g., "started", "completed", "failed")
    pub status: String,
    /// Optional duration in nanoseconds
    pub duration_ns: Option<i64>,
    /// Additional key-value metadata
    pub metadata: HashMap<String, String>,
}

impl AgentOperation {
    /// Validates the event payload
    pub fn validate(&self) -> Result<()> {
        if self.operation_type.is_empty() {
            return Err(ValidationError::Generic("operation_type cannot be empty".into()).into());
        }
        if self.target_type.is_empty() {
            return Err(ValidationError::Generic("target_type cannot be empty".into()).into());
        }
        if self.target_id.is_empty() {
            return Err(ValidationError::Generic("target_id cannot be empty".into()).into());
        }
        if self.status.is_empty() {
            return Err(ValidationError::Generic("status cannot be empty".into()).into());
        }
        Ok(())
    }
}

/// Payload for agent session termination
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AgentSessionEnded {
    /// Unique identifier for the agent
    pub agent_id: u64,
    /// Session identifier being terminated
    pub session_id: u64,
    /// Reason for termination
    pub reason: String,
    /// Additional key-value metadata
    pub metadata: HashMap<String, String>,
}

impl AgentSessionEnded {
    /// Validates the event payload
    pub fn validate(&self) -> Result<()> {
        if self.reason.is_empty() {
            return Err(ValidationError::Generic("reason cannot be empty".into()).into());
        }
        Ok(())
    }
}

/// Payload for code review notes
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ReviewNote {
    /// Agent or human ID who created the review
    pub author: u64,
    /// Type of target being reviewed ("commit", "file", "symbol", "pr")
    pub target_type: String,
    /// Identifier of the target (hash, path, etc.)
    pub target_id: String,
    /// Review note content
    pub note_text: String,
    /// Who can see this review
    pub visibility: EventVisibility,
    /// IDs of related items
    pub references: Vec<String>,
    /// Unix nanosecond timestamp
    pub created_at: i64,
}

impl ReviewNote {
    /// Validates the event payload
    pub fn validate(&self) -> Result<()> {
        if self.note_text.is_empty() {
            return Err(ValidationError::Generic("note_text cannot be empty".into()).into());
        }
        if !matches!(self.target_type.as_str(), "commit" | "file" | "symbol" | "pr") {
            return Err(ValidationError::Generic(format!(
                "target_type must be one of: commit, file, symbol, pr (got: {})",
                self.target_type
            )).into());
        }
        Ok(())
    }
}

/// Payload for AI-generated review summaries
#[derive(Debug, Clone, PartialEq)]
pub struct ReviewSummary {
    /// Agent ID that generated the summary
    pub generator_id: u64,
    /// Type of target being summarized
    pub target_type: String,
    /// Identifier of the target
    pub target_id: String,
    /// Generated summary content
    pub summary_text: String,
    /// Confidence score 0.0 to 1.0
    pub confidence: f32,
    /// LLM model used for generation
    pub model_id: String,
    /// Optional prompt identifier for reproducibility
    pub prompt_hash: Option<String>,
    /// Unix nanosecond timestamp
    pub created_at: i64,
}

impl ReviewSummary {
    /// Validates the event payload
    pub fn validate(&self) -> Result<()> {
        if self.summary_text.is_empty() {
            return Err(ValidationError::Generic("summary_text cannot be empty".into()).into());
        }
        if self.confidence < 0.0 || self.confidence > 1.0 {
            return Err(ValidationError::Generic(format!(
                "confidence must be in range [0.0, 1.0] (got: {})",
                self.confidence
            )).into());
        }
        Ok(())
    }
}

/// Time range for metric aggregation
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct TimeWindow {
    /// Start of window in nanoseconds
    pub start: i64,
    /// End of window in nanoseconds
    pub end: i64,
}

impl TimeWindow {
    /// Size of TimeWindow in bytes (16 bytes)
    pub const SIZE: usize = 16;

    /// Validates the time window
    pub fn validate(&self) -> Result<()> {
        if self.start > self.end {
            return Err(ValidationError::Generic("time window start must be <= end".into()).into());
        }
        Ok(())
    }
}

/// Hints for correlating metrics with other events
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CorrelationHints {
    /// Commit range (e.g., "abc123..def456")
    pub commit_range: Option<String>,
    /// Related session IDs
    pub session_ids: Vec<u64>,
}

/// Payload for performance metric samples
#[derive(Debug, Clone, PartialEq)]
pub struct PerfSample {
    /// Name of the metric (e.g., "latency", "throughput")
    pub metric_name: String,
    /// Metric dimensions (query_name, codepath, etc.)
    pub dimensions: HashMap<String, String>,
    /// Metric value
    pub value: f64,
    /// Unit of measurement (e.g., "ms", "ops/sec")
    pub unit: String,
    /// Time range this sample represents
    pub timestamp_window: TimeWindow,
    /// Hints for correlating with commits/sessions
    pub correlation_hints: CorrelationHints,
}

impl PerfSample {
    /// Validates the event payload
    pub fn validate(&self) -> Result<()> {
        if self.metric_name.is_empty() {
            return Err(ValidationError::Generic("metric_name cannot be empty".into()).into());
        }
        if self.unit.is_empty() {
            return Err(ValidationError::Generic("unit cannot be empty".into()).into());
        }
        self.timestamp_window.validate()?;
        Ok(())
    }
}

/// Payload for detected performance regressions
#[derive(Debug, Clone, PartialEq)]
pub struct PerfRegression {
    /// Name of the regressed metric
    pub metric_name: String,
    /// Baseline value before regression
    pub baseline_value: f64,
    /// Current value showing regression
    pub current_value: f64,
    /// Percentage of regression
    pub regression_percent: f32,
    /// Severity level ("minor", "moderate", "severe")
    pub severity: String,
    /// When regression was detected
    pub detected_at: i64,
    /// Suspected cause
    pub likely_cause: Option<String>,
    /// Commits correlated with regression
    pub correlated_commits: Vec<String>,
}

impl PerfRegression {
    /// Validates the event payload
    pub fn validate(&self) -> Result<()> {
        if self.regression_percent <= 0.0 {
            return Err(ValidationError::Generic("regression_percent must be > 0".into()).into());
        }
        if !matches!(self.severity.as_str(), "minor" | "moderate" | "severe") {
            return Err(ValidationError::Generic(format!(
                "severity must be one of: minor, moderate, severe (got: {})",
                self.severity
            )).into());
        }
        Ok(())
    }
}

/// Breakpoint definition
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Breakpoint {
    /// Path to source file
    pub file_path: String,
    /// Line number (1-indexed)
    pub line: u32,
    /// Optional breakpoint condition
    pub condition: Option<String>,
    /// Number of times breakpoint was hit
    pub hit_count: u32,
}

impl Breakpoint {
    /// Validates the breakpoint
    pub fn validate(&self) -> Result<()> {
        if self.file_path.is_empty() {
            return Err(ValidationError::Generic("file_path cannot be empty".into()).into());
        }
        if self.line == 0 {
            return Err(ValidationError::Generic("line must be >= 1".into()).into());
        }
        Ok(())
    }
}

/// References for debugging session
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DebugReferences {
    /// Related commit hashes
    pub commit_ids: Vec<String>,
    /// Related symbol names
    pub symbol_names: Vec<String>,
}

/// Payload for debugging session events
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DebugSession {
    /// Debugger tool name ("lldb", "gdb", "python-debugger")
    pub tool: String,
    /// Unique session identifier
    pub session_id: u64,
    /// Active breakpoints
    pub breakpoints: Vec<Breakpoint>,
    /// Optional sampled stack trace
    pub stack_summary: Option<String>,
    /// Related commit IDs and symbol names
    pub references: DebugReferences,
}

impl DebugSession {
    /// Validates the event payload
    pub fn validate(&self) -> Result<()> {
        if self.tool.is_empty() {
            return Err(ValidationError::Generic("tool cannot be empty".into()).into());
        }
        for bp in &self.breakpoints {
            bp.validate()?;
        }
        Ok(())
    }
}

/// Payload for debug state snapshots
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DebugSnapshot {
    /// Session this snapshot belongs to
    pub session_id: u64,
    /// Snapshot data (could be stack trace, variable values, etc.)
    pub snapshot_data: String,
    /// Optional context information
    pub context: HashMap<String, String>,
}

impl DebugSnapshot {
    /// Validates the event payload
    pub fn validate(&self) -> Result<()> {
        if self.snapshot_data.is_empty() {
            return Err(ValidationError::Generic("snapshot_data cannot be empty".into()).into());
        }
        Ok(())
    }
}

/// Payload for version control commit events
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct VcsCommit {
    /// Full commit hash
    pub commit_hash: String,
    /// Author identifier
    pub author_id: u64,
    /// Commit message text
    pub commit_message: String,
    /// List of changed file paths
    pub changed_files: Vec<String>,
    /// Parent commit hashes
    pub parent_commits: Vec<String>,
    /// Branch name
    pub branch: String,
    /// Commit timestamp
    pub timestamp: i64,
}

impl VcsCommit {
    /// Validates the event payload
    pub fn validate(&self) -> Result<()> {
        if self.commit_hash.is_empty() {
            return Err(ValidationError::Generic("commit_hash cannot be empty".into()).into());
        }
        if self.branch.is_empty() {
            return Err(ValidationError::Generic("branch cannot be empty".into()).into());
        }
        Ok(())
    }
}

/// Payload for branch operation events
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct VcsBranch {
    /// Branch operation type ("create", "delete", "switch", "rename")
    pub operation: String,
    /// Branch name
    pub branch_name: String,
    /// Optional old branch name (for rename operations)
    pub old_name: Option<String>,
    /// Optional actor who performed the operation
    pub actor_id: Option<u64>,
    /// Operation timestamp
    pub timestamp: i64,
}

impl VcsBranch {
    /// Validates the event payload
    pub fn validate(&self) -> Result<()> {
        if self.operation.is_empty() {
            return Err(ValidationError::Generic("operation cannot be empty".into()).into());
        }
        if self.branch_name.is_empty() {
            return Err(ValidationError::Generic("branch_name cannot be empty".into()).into());
        }
        if !matches!(self.operation.as_str(), "create" | "delete" | "switch" | "rename") {
            return Err(ValidationError::Generic(format!(
                "operation must be one of: create, delete, switch, rename (got: {})",
                self.operation
            )).into());
        }
        Ok(())
    }
}

/// Query filter for event searches
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct EventFilter {
    /// Filter by event types
    pub event_types: Option<Vec<EventType>>,
    /// Filter by actor
    pub actor_id: Option<u64>,
    /// Filter by session
    pub session_id: Option<u64>,
    /// Filter events after this time
    pub start_time: Option<i64>,
    /// Filter events before this time
    pub end_time: Option<i64>,
    /// Minimum visibility level
    pub visibility_min: Option<EventVisibility>,
    /// Filter by target type (for reviews)
    pub target_type: Option<String>,
    /// Filter by target ID (for reviews)
    pub target_id: Option<String>,
    /// Maximum number of results
    pub limit: Option<usize>,
}

impl EventFilter {
    /// Creates a new EventFilter with default values
    pub fn new() -> Self {
        Self::default()
    }

    /// Validates the filter
    pub fn validate(&self) -> Result<()> {
        if let (Some(start), Some(end)) = (self.start_time, self.end_time) {
            if start > end {
                return Err(ValidationError::Generic("start_time must be <= end_time".into()).into());
            }
        }
        Ok(())
    }
}

/// Query result containing header and payload
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct EventResult {
    /// Event metadata
    pub header: EventHeader,
    /// Serialized payload data
    pub payload: Vec<u8>,
}

impl EventResult {
    /// Creates a new EventResult
    pub fn new(header: EventHeader, payload: Vec<u8>) -> Self {
        Self { header, payload }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_event_type_category() {
        assert_eq!(EventType::AgentSessionStarted.category(), 0x1);
        assert_eq!(EventType::ReviewNote.category(), 0x2);
        assert_eq!(EventType::PerfSample.category(), 0x3);
        assert_eq!(EventType::DebugSession.category(), 0x4);
        assert_eq!(EventType::VcsCommit.category(), 0x5);
    }

    #[test]
    fn test_event_type_from_raw() {
        assert_eq!(
            EventType::from_raw(0x1000),
            Some(EventType::AgentSessionStarted)
        );
        assert_eq!(EventType::from_raw(0x9999), None);
    }

    #[test]
    fn test_event_visibility_ordering() {
        assert!(EventVisibility::Private < EventVisibility::Team);
        assert!(EventVisibility::Team < EventVisibility::Public);
    }

    #[test]
    fn test_event_visibility_from_raw() {
        assert_eq!(EventVisibility::from_raw(0), Some(EventVisibility::Private));
        assert_eq!(EventVisibility::from_raw(1), Some(EventVisibility::Team));
        assert_eq!(EventVisibility::from_raw(2), Some(EventVisibility::Public));
        assert_eq!(EventVisibility::from_raw(3), None);
    }

    #[test]
    fn test_event_header_validation() {
        let mut header = EventHeader::new(
            EventType::AgentSessionStarted,
            12345,
            1,
            Some(100),
            EventVisibility::Team,
            1024,
        );
        assert!(header.validate().is_ok());

        header.payload_len = MAX_EVENT_PAYLOAD_SIZE + 1;
        assert!(header.validate().is_err());
    }

    #[test]
    fn test_agent_session_started_validation() {
        let event = AgentSessionStarted {
            agent_id: 1,
            agent_version: "1.0.0".to_string(),
            session_purpose: "Test session".to_string(),
            metadata: HashMap::new(),
        };
        assert!(event.validate().is_ok());

        let invalid = AgentSessionStarted {
            agent_id: 1,
            agent_version: "".to_string(),
            session_purpose: "Test".to_string(),
            metadata: HashMap::new(),
        };
        assert!(invalid.validate().is_err());
    }

    #[test]
    fn test_agent_operation_validation() {
        let op = AgentOperation {
            operation_type: "commit".to_string(),
            operation_id: 1,
            target_type: "file".to_string(),
            target_id: "/path/to/file".to_string(),
            status: "completed".to_string(),
            duration_ns: Some(1_000_000),
            metadata: HashMap::new(),
        };
        assert!(op.validate().is_ok());
    }

    #[test]
    fn test_review_note_validation() {
        let note = ReviewNote {
            author: 1,
            target_type: "commit".to_string(),
            target_id: "abc123".to_string(),
            note_text: "Good work!".to_string(),
            visibility: EventVisibility::Team,
            references: vec![],
            created_at: 12345,
        };
        assert!(note.validate().is_ok());

        let invalid = ReviewNote {
            target_type: "invalid".to_string(),
            ..note.clone()
        };
        assert!(invalid.validate().is_err());
    }

    #[test]
    fn test_review_summary_validation() {
        let summary = ReviewSummary {
            generator_id: 1,
            target_type: "commit".to_string(),
            target_id: "abc123".to_string(),
            summary_text: "Summary".to_string(),
            confidence: 0.95,
            model_id: "gpt-4".to_string(),
            prompt_hash: Some("hash".to_string()),
            created_at: 12345,
        };
        assert!(summary.validate().is_ok());

        let invalid = ReviewSummary {
            confidence: 1.5,
            ..summary.clone()
        };
        assert!(invalid.validate().is_err());
    }

    #[test]
    fn test_time_window_validation() {
        let window = TimeWindow { start: 100, end: 200 };
        assert!(window.validate().is_ok());

        let invalid = TimeWindow { start: 200, end: 100 };
        assert!(invalid.validate().is_err());
    }

    #[test]
    fn test_perf_regression_validation() {
        let regression = PerfRegression {
            metric_name: "latency".to_string(),
            baseline_value: 100.0,
            current_value: 120.0,
            regression_percent: 20.0,
            severity: "moderate".to_string(),
            detected_at: 12345,
            likely_cause: None,
            correlated_commits: vec![],
        };
        assert!(regression.validate().is_ok());

        let invalid = PerfRegression {
            severity: "critical".to_string(),
            ..regression.clone()
        };
        assert!(invalid.validate().is_err());
    }

    #[test]
    fn test_breakpoint_validation() {
        let bp = Breakpoint {
            file_path: "/path/to/file".to_string(),
            line: 42,
            condition: Some("x > 0".to_string()),
            hit_count: 5,
        };
        assert!(bp.validate().is_ok());

        let invalid = Breakpoint {
            line: 0,
            ..bp.clone()
        };
        assert!(invalid.validate().is_err());
    }

    #[test]
    fn test_vcs_commit_validation() {
        let commit = VcsCommit {
            commit_hash: "abc123".to_string(),
            author_id: 1,
            commit_message: "Test".to_string(),
            changed_files: vec![],
            parent_commits: vec![],
            branch: "main".to_string(),
            timestamp: 12345,
        };
        assert!(commit.validate().is_ok());
    }

    #[test]
    fn test_vcs_branch_validation() {
        let branch = VcsBranch {
            operation: "create".to_string(),
            branch_name: "feature".to_string(),
            old_name: None,
            actor_id: Some(1),
            timestamp: 12345,
        };
        assert!(branch.validate().is_ok());

        let invalid = VcsBranch {
            operation: "invalid".to_string(),
            ..branch.clone()
        };
        assert!(invalid.validate().is_err());
    }

    #[test]
    fn test_event_filter_validation() {
        let filter = EventFilter {
            start_time: Some(100),
            end_time: Some(200),
            ..Default::default()
        };
        assert!(filter.validate().is_ok());

        let invalid = EventFilter {
            start_time: Some(200),
            end_time: Some(100),
            ..Default::default()
        };
        assert!(invalid.validate().is_err());
    }
}
