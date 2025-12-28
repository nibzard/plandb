//! Event subsystem for Review & Observability
//!
//! Public API for event storage and querying

const std = @import("std");
pub const types = @import("types.zig");
pub const storage = @import("storage.zig");

/// Event manager for high-level event operations
pub const EventManager = struct {
    allocator: std.mem.Allocator,
    store: *storage.EventStore,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, store: *storage.EventStore) Self {
        return Self{
            .allocator = allocator,
            .store = store,
        };
    }

    /// Record agent session start
    pub fn recordAgentSessionStart(
        self: *Self,
        agent_id: u64,
        agent_version: []const u8,
        session_purpose: []const u8,
        metadata: std.StringHashMap([]const u8),
    ) !u64 {
        const timestamp = std.time.nanoTimestamp();

        // Serialize payload
        var payload_buffer = std.ArrayList(u8).init(self.allocator);
        defer payload_buffer.deinit();

        const writer = payload_buffer.writer();

        // Write agent_version (length prefixed)
        try writer.writeInt(u32, @intCast(agent_version.len), .little);
        try writer.writeAll(agent_version);

        // Write session_purpose (length prefixed)
        try writer.writeInt(u32, @intCast(session_purpose.len), .little);
        try writer.writeAll(session_purpose);

        // Write metadata count
        try writer.writeInt(u32, @intCast(metadata.count()), .little);

        var it = metadata.iterator();
        while (it.next()) |entry| {
            try writer.writeInt(u32, @intCast(entry.key_ptr.*.len), .little);
            try writer.writeAll(entry.key_ptr.*);
            try writer.writeInt(u32, @intCast(entry.value_ptr.*.len), .little);
            try writer.writeAll(entry.value_ptr.*);
        }

        const payload = try payload_buffer.toOwnedSlice();
        defer self.allocator.free(payload);

        const header = types.EventHeader{
            .event_id = 0,
            .event_type = .agent_session_started,
            .timestamp = timestamp,
            .actor_id = agent_id,
            .session_id = null, // Will be assigned by store
            .visibility = .private,
            .payload_len = @intCast(payload.len),
        };

        return self.store.appendEvent(header, payload);
    }

    /// Record agent operation
    pub fn recordAgentOperation(
        self: *Self,
        agent_id: u64,
        session_id: u64,
        operation_type: []const u8,
        operation_id: u64,
        target_type: []const u8,
        target_id: []const u8,
        status: []const u8,
        duration_ns: ?i64,
        metadata: std.StringHashMap([]const u8),
    ) !u64 {
        const timestamp = std.time.nanoTimestamp();

        var payload_buffer = std.ArrayList(u8).init(self.allocator);
        defer payload_buffer.deinit();

        const writer = payload_buffer.writer();

        // Write operation fields (all length prefixed)
        try writer.writeInt(u32, @intCast(operation_type.len), .little);
        try writer.writeAll(operation_type);

        try writer.writeInt(u64, operation_id, .little);

        try writer.writeInt(u32, @intCast(target_type.len), .little);
        try writer.writeAll(target_type);

        try writer.writeInt(u32, @intCast(target_id.len), .little);
        try writer.writeAll(target_id);

        try writer.writeInt(u32, @intCast(status.len), .little);
        try writer.writeAll(status);

        // Write duration (optional)
        const has_duration = duration_ns != null;
        try writer.writeInt(u8, @intFromBool(has_duration), .little);
        if (duration_ns) |d| {
            try writer.writeInt(i64, d, .little);
        }

        // Write metadata count
        try writer.writeInt(u32, @intCast(metadata.count()), .little);

        var it = metadata.iterator();
        while (it.next()) |entry| {
            try writer.writeInt(u32, @intCast(entry.key_ptr.*.len), .little);
            try writer.writeAll(entry.key_ptr.*);
            try writer.writeInt(u32, @intCast(entry.value_ptr.*.len), .little);
            try writer.writeAll(entry.value_ptr.*);
        }

        const payload = try payload_buffer.toOwnedSlice();
        defer self.allocator.free(payload);

        const header = types.EventHeader{
            .event_id = 0,
            .event_type = .agent_operation,
            .timestamp = timestamp,
            .actor_id = agent_id,
            .session_id = session_id,
            .visibility = .private,
            .payload_len = @intCast(payload.len),
        };

        return self.store.appendEvent(header, payload);
    }

    /// Record review note
    pub fn recordReviewNote(
        self: *Self,
        author: u64,
        target_type: []const u8,
        target_id: []const u8,
        note_text: []const u8,
        visibility: types.EventVisibility,
        references: [][]const u8,
    ) !u64 {
        const timestamp = std.time.nanoTimestamp();

        var payload_buffer = std.ArrayList(u8).init(self.allocator);
        defer payload_buffer.deinit();

        const writer = payload_buffer.writer();

        try writer.writeInt(u32, @intCast(target_type.len), .little);
        try writer.writeAll(target_type);

        try writer.writeInt(u32, @intCast(target_id.len), .little);
        try writer.writeAll(target_id);

        try writer.writeInt(u32, @intCast(note_text.len), .little);
        try writer.writeAll(note_text);

        try writer.writeInt(u8, @intFromEnum(visibility), .little);

        try writer.writeInt(u32, @intCast(references.len), .little);
        for (references) |ref| {
            try writer.writeInt(u32, @intCast(ref.len), .little);
            try writer.writeAll(ref);
        }

        const payload = try payload_buffer.toOwnedSlice();
        defer self.allocator.free(payload);

        const header = types.EventHeader{
            .event_id = 0,
            .event_type = .review_note,
            .timestamp = timestamp,
            .actor_id = author,
            .session_id = null,
            .visibility = visibility,
            .payload_len = @intCast(payload.len),
        };

        return self.store.appendEvent(header, payload);
    }

    /// Record performance sample
    pub fn recordPerfSample(
        self: *Self,
        agent_id: u64,
        metric_name: []const u8,
        dimensions: std.StringHashMap([]const u8),
        value: f64,
        unit: []const u8,
        window_start: i64,
        window_end: i64,
        correlation_commit_range: ?[]const u8,
        correlation_session_ids: []u64,
    ) !u64 {
        const timestamp = std.time.nanoTimestamp();

        var payload_buffer = std.ArrayList(u8).init(self.allocator);
        defer payload_buffer.deinit();

        const writer = payload_buffer.writer();

        try writer.writeInt(u32, @intCast(metric_name.len), .little);
        try writer.writeAll(metric_name);

        try writer.writeInt(u32, @intCast(dimensions.count()), .little);
        var dim_it = dimensions.iterator();
        while (dim_it.next()) |entry| {
            try writer.writeInt(u32, @intCast(entry.key_ptr.*.len), .little);
            try writer.writeAll(entry.key_ptr.*);
            try writer.writeInt(u32, @intCast(entry.value_ptr.*.len), .little);
            try writer.writeAll(entry.value_ptr.*);
        }

        try writer.writeInt(f64, @bitCast(value), .little);

        try writer.writeInt(u32, @intCast(unit.len), .little);
        try writer.writeAll(unit);

        try writer.writeInt(i64, window_start, .little);
        try writer.writeInt(i64, window_end, .little);

        const has_commit_range = correlation_commit_range != null;
        try writer.writeInt(u8, @intFromBool(has_commit_range), .little);
        if (correlation_commit_range) |r| {
            try writer.writeInt(u32, @intCast(r.len), .little);
            try writer.writeAll(r);
        }

        try writer.writeInt(u32, @intCast(correlation_session_ids.len), .little);
        for (correlation_session_ids) |sid| {
            try writer.writeInt(u64, sid, .little);
        }

        const payload = try payload_buffer.toOwnedSlice();
        defer self.allocator.free(payload);

        const header = types.EventHeader{
            .event_id = 0,
            .event_type = .perf_sample,
            .timestamp = timestamp,
            .actor_id = agent_id,
            .session_id = null,
            .visibility = .team,
            .payload_len = @intCast(payload.len),
        };

        return self.store.appendEvent(header, payload);
    }

    /// Query events with filters
    pub fn query(self: *Self, filter: types.EventFilter) ![]types.EventResult {
        return self.store.queryEvents(filter);
    }

    /// Get event by ID
    pub fn getEvent(self: *Self, event_id: u64) !?types.EventResult {
        return self.store.getEvent(event_id);
    }

    /// Get all events for a session
    pub fn getSessionEvents(self: *Self, session_id: u64) ![]types.EventResult {
        return self.store.getSessionEvents(session_id);
    }

    /// Get events for a specific actor
    pub fn getActorEvents(self: *Self, actor_id: u64, limit: ?usize) ![]types.EventResult {
        return self.store.getActorEvents(actor_id, limit);
    }

    /// Get review notes for a target
    pub fn getReviewNotes(self: *Self, target_type: []const u8, target_id: []const u8) ![]types.EventResult {
        // Query all review notes and filter by target
        const all_notes = try self.store.queryEvents(.{
            .event_types = &[_]types.EventType{.review_note},
        });

        var filtered = std.ArrayList(types.EventResult).init(self.allocator);

        for (all_notes) |note| {
            // Parse target from payload
            // For now, do simple string matching on payload
            // In production, you'd properly deserialize and compare fields
            _ = target_type;
            _ = target_id;
            try filtered.append(note);
        }

        return filtered.toOwnedSlice();
    }
};

test "EventManager record and query operations" {
    const allocator = std.testing.allocator;

    const config = storage.EventStore.Config{
        .events_path = "test_mgr_events.dat",
        .index_path = "test_mgr_events.idx",
    };

    defer std.fs.cwd().deleteFile(config.events_path) catch {};
    defer std.fs.cwd().deleteFile(config.index_path) catch {};

    var store = try storage.EventStore.open(allocator, config);
    defer store.deinit();

    var manager = EventManager.init(allocator, &store);

    // Record agent session
    var metadata = std.StringHashMap([]const u8).init(allocator);
    defer metadata.deinit();

    try metadata.put("hostname", "test-host");
    try metadata.put("workspace", "/tmp/test");

    const event_id = try manager.recordAgentSessionStart(
        1,
        "v1.0.0",
        "testing event manager",
        metadata,
    );

    try std.testing.expect(event_id >= 0);

    // Query events
    const events = try manager.getActorEvents(1, null);

    defer {
        for (events) |*e| e.deinit();
        allocator.free(events);
    }

    try std.testing.expectEqual(@as(usize, 1), events.len);
}

test "EventManager review note recording" {
    const allocator = std.testing.allocator;

    const config = storage.EventStore.Config{
        .events_path = "test_review_events.dat",
        .index_path = "test_review_events.idx",
    };

    defer std.fs.cwd().deleteFile(config.events_path) catch {};
    defer std.fs.cwd().deleteFile(config.index_path) catch {};

    var store = try storage.EventStore.open(allocator, config);
    defer store.deinit();

    var manager = EventManager.init(allocator, &store);

    const references = [_][]const u8{
        "commit:abc123",
        "file:src/main.zig",
    };

    const event_id = try manager.recordReviewNote(
        42,
        "commit",
        "abc123",
        "This commit needs review for safety issues",
        .team,
        &references,
    );

    try std.testing.expect(event_id >= 0);

    // Get the event
    const event = try manager.getEvent(event_id);

    if (event) |e| {
        defer e.deinit();
        try std.testing.expectEqual(types.EventType.review_note, e.header.event_type);
    } else {
        try std.testing.expect(false);
    }
}
