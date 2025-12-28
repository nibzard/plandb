//! Event types for Review & Observability system
//!
//! Defines typed events that are versioned and time-travel-compatible
//! but logically separate from the hot commit path

const std = @import("std");

/// Event types for review and observability
pub const EventType = enum(u16) {
    // Agent lifecycle events
    agent_session_started = 0x1000,
    agent_session_ended = 0x1001,
    agent_operation = 0x1002,

    // Review events
    review_note = 0x2000,
    review_summary = 0x2001,

    // Performance events
    perf_sample = 0x3000,
    perf_regression = 0x3001,

    // Debug events
    debug_session = 0x4000,
    debug_snapshot = 0x4001,

    // VCS events
    vcs_commit = 0x5000,
    vcs_branch = 0x5001,
};

/// Event visibility levels
pub const EventVisibility = enum(u8) {
    private = 0, // Private to agent
    team = 1,    // Shared within team
    public = 2,  // Publicly visible
};

/// Base event record header
pub const EventHeader = struct {
    event_id: u64,          // Unique event ID (LSN-equivalent)
    event_type: EventType,  // Type of event
    timestamp: i64,         // Unix nanosecond timestamp
    actor_id: u64,          // Agent or human ID
    session_id: ?u64,       // Optional session ID
    visibility: EventVisibility,
    payload_len: u32,       // Size of payload in bytes

    pub const SIZE: usize = @sizeOf(@This());

    pub fn validate(self: *const EventHeader) !void {
        if (self.payload_len > MAX_EVENT_PAYLOAD_SIZE) {
            return error.PayloadTooLarge;
        }
    }
};

/// Agent session started event
pub const AgentSessionStarted = struct {
    agent_id: u64,
    agent_version: []const u8,
    session_purpose: []const u8,
    metadata: std.StringHashMap([]const u8),

    pub fn deinit(self: *AgentSessionStarted, allocator: std.mem.Allocator) void {
        allocator.free(self.agent_version);
        allocator.free(self.session_purpose);

        var it = self.metadata.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        self.metadata.deinit();
    }
};

/// Agent operation event
pub const AgentOperation = struct {
    operation_type: []const u8,     // e.g., "commit", "query", "analyze"
    operation_id: u64,
    target_type: []const u8,        // e.g., "file", "symbol", "cartridge"
    target_id: []const u8,          // e.g., path, symbol name
    status: []const u8,             // e.g., "started", "completed", "failed"
    duration_ns: ?i64,              // Optional duration
    metadata: std.StringHashMap([]const u8),

    pub fn deinit(self: *AgentOperation, allocator: std.mem.Allocator) void {
        allocator.free(self.operation_type);
        allocator.free(self.target_type);
        allocator.free(self.target_id);
        allocator.free(self.status);

        var it = self.metadata.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        self.metadata.deinit();
    }
};

/// Review note event
pub const ReviewNote = struct {
    author: u64,                    // Agent or human ID
    target_type: []const u8,        // "commit", "file", "symbol", "pr"
    target_id: []const u8,          // Commit hash, file path, etc.
    note_text: []const u8,
    visibility: EventVisibility,
    references: [][]const u8,       // IDs of related items
    created_at: i64,

    pub fn deinit(self: *ReviewNote, allocator: std.mem.Allocator) void {
        allocator.free(self.target_type);
        allocator.free(self.target_id);
        allocator.free(self.note_text);

        for (self.references) |ref| {
            allocator.free(ref);
        }
        allocator.free(self.references);
    }
};

/// Review summary event (generated)
pub const ReviewSummary = struct {
    generator_id: u64,              // Agent ID that generated summary
    target_type: []const u8,
    target_id: []const u8,
    summary_text: []const u8,
    confidence: f32,                // 0.0 to 1.0
    model_id: []const u8,           // LLM model used
    prompt_hash: ?[]const u8,       // Optional prompt identifier
    created_at: i64,

    pub fn deinit(self: *ReviewSummary, allocator: std.mem.Allocator) void {
        allocator.free(self.target_type);
        allocator.free(self.target_id);
        allocator.free(self.summary_text);
        allocator.free(self.model_id);
        if (self.prompt_hash) |h| allocator.free(h);
    }
};

/// Performance sample event
pub const PerfSample = struct {
    metric_name: []const u8,        // e.g., "latency", "throughput"
    dimensions: std.StringHashMap([]const u8), // query_name, codepath, etc.
    value: f64,
    unit: []const u8,               // e.g., "ms", "ops/sec"
    timestamp_window: struct {
        start: i64,
        end: i64,
    },
    correlation_hints: struct {
        commit_range: ?[]const u8,  // e.g., "abc123..def456"
        session_ids: []u64,
    },

    pub fn deinit(self: *PerfSample, allocator: std.mem.Allocator) void {
        allocator.free(self.metric_name);
        allocator.free(self.unit);

        var it = self.dimensions.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        self.dimensions.deinit();

        if (self.correlation_hints.commit_range) |r| {
            allocator.free(r);
        }
        allocator.free(self.correlation_hints.session_ids);
    }
};

/// Performance regression event
pub const PerfRegression = struct {
    metric_name: []const u8,
    baseline_value: f64,
    current_value: f64,
    regression_percent: f32,
    severity: []const u8,           // "minor", "moderate", "severe"
    detected_at: i64,
    likely_cause: ?[]const u8,
    correlated_commits: [][]const u8,

    pub fn deinit(self: *PerfRegression, allocator: std.mem.Allocator) void {
        allocator.free(self.metric_name);
        allocator.free(self.severity);
        if (self.likely_cause) |c| allocator.free(c);

        for (self.correlated_commits) |c| {
            allocator.free(c);
        }
        allocator.free(self.correlated_commits);
    }
};

/// Debug session event
pub const DebugSession = struct {
    tool: []const u8,               // "lldb", "gdb", "python-debugger"
    session_id: u64,
    breakpoints: []Breakpoint,
    stack_summary: ?[]const u8,     // Optional sampled stack trace
    references: DebugReferences,

    pub fn deinit(self: *DebugSession, allocator: std.mem.Allocator) void {
        allocator.free(self.tool);

        for (self.breakpoints) |*bp| {
            bp.deinit(allocator);
        }
        allocator.free(self.breakpoints);

        if (self.stack_summary) |s| allocator.free(s);
        self.references.deinit(allocator);
    }
};

pub const Breakpoint = struct {
    file_path: []const u8,
    line: u32,
    condition: ?[]const u8,
    hit_count: u32,

    pub fn deinit(self: *Breakpoint, allocator: std.mem.Allocator) void {
        allocator.free(self.file_path);
        if (self.condition) |c| allocator.free(c);
    }
};

pub const DebugReferences = struct {
    commit_ids: [][]const u8,
    symbol_names: [][]const u8,

    pub fn deinit(self: *DebugReferences, allocator: std.mem.Allocator) void {
        for (self.commit_ids) |c| allocator.free(c);
        allocator.free(self.commit_ids);

        for (self.symbol_names) |s| allocator.free(s);
        allocator.free(self.symbol_names);
    }
};

/// VCS commit event
pub const VcsCommit = struct {
    commit_hash: []const u8,
    author_id: u64,
    commit_message: []const u8,
    changed_files: [][]const u8,
    parent_commits: [][]const u8,
    branch: []const u8,
    timestamp: i64,

    pub fn deinit(self: *VcsCommit, allocator: std.mem.Allocator) void {
        allocator.free(self.commit_hash);
        allocator.free(self.commit_message);
        allocator.free(self.branch);

        for (self.changed_files) |f| allocator.free(f);
        allocator.free(self.changed_files);

        for (self.parent_commits) |p| allocator.free(p);
        allocator.free(self.parent_commits);
    }
};

/// Maximum event payload size (1MB default, configurable)
pub const MAX_EVENT_PAYLOAD_SIZE: u32 = 1024 * 1024;

/// Event query filters
pub const EventFilter = struct {
    event_types: ?[]EventType = null,
    actor_id: ?u64 = null,
    session_id: ?u64 = null,
    start_time: ?i64 = null,
    end_time: ?i64 = null,
    visibility_min: ?EventVisibility = null,
    target_type: ?[]const u8 = null,
    target_id: ?[]const u8 = null,
    limit: ?usize = null,
};

/// Event query result
pub const EventResult = struct {
    header: EventHeader,
    payload: []const u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *EventResult) void {
        self.allocator.free(self.payload);
    }
};

test "EventHeader validation" {
    var header = EventHeader{
        .event_id = 1,
        .event_type = .agent_session_started,
        .timestamp = std.time.nanoTimestamp(),
        .actor_id = 42,
        .session_id = 1,
        .visibility = .private,
        .payload_len = 100,
    };

    try std.testing.expect((try header.validate()) == void{});
}

test "EventHeader payload_too_large" {
    var header = EventHeader{
        .event_id = 1,
        .event_type = .agent_session_started,
        .timestamp = std.time.nanoTimestamp(),
        .actor_id = 42,
        .session_id = 1,
        .visibility = .private,
        .payload_len = MAX_EVENT_PAYLOAD_SIZE + 1,
    };

    try std.testing.expectError(error.PayloadTooLarge, header.validate());
}
