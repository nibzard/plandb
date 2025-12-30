//! Event storage for Review & Observability system
//!
//! Provides append-only event storage with time-travel compatibility
//! Events are logically separate from core commit path

const std = @import("std");
const types = @import("types.zig");

pub const EventStore = struct {
    allocator: std.mem.Allocator,
    events_file: std.fs.File,
    index_file: std.fs.File,
    next_event_id: u64,
    index: std.AutoHashMap(u64, EventIndexEntry),
    max_payload_size: u32,

    const Self = @This();

    /// Index entry for fast event lookups
    const EventIndexEntry = struct {
        file_offset: u64,
        event_type: types.EventType,
        timestamp: i64,
        actor_id: u64,
        session_id: ?u64,
        visibility: types.EventVisibility,
    };

    /// Event record framing: [Header(24)][Payload(N)][Trailer(8)]
    const EVENT_HEADER_SIZE = @sizeOf(EventRecordHeader);
    const EVENT_TRAILER_SIZE = @sizeOf(EventRecordTrailer);

    const EventRecordHeader = struct {
        event_id: u64,
        event_type: u16,
        timestamp: i64,
        actor_id: u64,
        payload_len: u32,
    };

    const EventRecordTrailer = struct {
        magic: u32 = 0x564E5452, // "EVNT"
        total_len: u32,
    };

    pub const Config = struct {
        max_payload_size: u32 = types.MAX_EVENT_PAYLOAD_SIZE,
        events_path: []const u8 = "northstar_events.dat",
        index_path: []const u8 = "northstar_events.idx",
    };

    /// Open existing event store or create new
    pub fn open(allocator: std.mem.Allocator, config: Config) !Self {
        const events_file = std.fs.cwd().openFile(config.events_path, .{
            .mode = .read_write,
        }) catch |err| switch (err) {
            error.FileNotFound => try std.fs.cwd().createFile(config.events_path, .{
                .truncate = true,
                .read = true,
            }),
            else => return err,
        };
        errdefer events_file.close();

        const index_file = std.fs.cwd().openFile(config.index_path, .{
            .mode = .read_write,
        }) catch |err| switch (err) {
            error.FileNotFound => try std.fs.cwd().createFile(config.index_path, .{
                .truncate = true,
                .read = true,
            }),
            else => return err,
        };
        errdefer index_file.close();

        var store = Self{
            .allocator = allocator,
            .events_file = events_file,
            .index_file = index_file,
            .next_event_id = 0,
            .index = std.AutoHashMap(u64, EventIndexEntry).init(allocator),
            .max_payload_size = config.max_payload_size,
        };

        // Load existing index if any
        try store.loadIndex();

        // Scan events file to find next event ID
        const events_size = try store.events_file.getEndPos();
        if (events_size > 0) {
            store.next_event_id = try store.scanHighestEventId();
        }

        return store;
    }

    pub fn deinit(self: *Self) void {
        // Save index before closing
        self.saveIndex() catch {};
        self.index.deinit();
        self.events_file.close();
        self.index_file.close();
    }

    /// Append an event to the store
    pub fn appendEvent(self: *Self, event: types.EventHeader, payload: []const u8) !u64 {
        // Validate payload size
        if (payload.len > self.max_payload_size) {
            return error.PayloadTooLarge;
        }

        // Generate event ID and create mutable copy
        const event_id = self.next_event_id;
        self.next_event_id += 1;
        var mut_event = event;
        mut_event.event_id = event_id;

        // Validate event
        try mut_event.validate();

        // Calculate record size
        const record_size = EVENT_HEADER_SIZE + payload.len + EVENT_TRAILER_SIZE;

        // Seek to end of events file
        const file_offset = try self.events_file.getEndPos();

        // Write header
        var header = EventRecordHeader{
            .event_id = event_id,
            .event_type = @intFromEnum(mut_event.event_type),
            .timestamp = mut_event.timestamp,
            .actor_id = mut_event.actor_id,
            .payload_len = @intCast(payload.len),
        };

        var offset = file_offset;
        _ = try self.events_file.pwriteAll(std.mem.asBytes(&header), offset);
        offset += @sizeOf(EventRecordHeader);

        // Write payload
        _ = try self.events_file.pwriteAll(payload, offset);
        offset += payload.len;

        // Write trailer
        var trailer = EventRecordTrailer{
            .magic = 0x564E5452,
            .total_len = @intCast(record_size),
        };
        _ = try self.events_file.pwriteAll(std.mem.asBytes(&trailer), offset);

        // Update index
        try self.index.put(event_id, EventIndexEntry{
            .file_offset = file_offset,
            .event_type = mut_event.event_type,
            .timestamp = mut_event.timestamp,
            .actor_id = mut_event.actor_id,
            .session_id = mut_event.session_id,
            .visibility = mut_event.visibility,
        });

        return event_id;
    }

    /// Query events by filter
    pub fn queryEvents(self: *Self, filter: types.EventFilter) ![]types.EventResult {
        var results = std.array_list.AlignedManaged(types.EventResult, null).init(self.allocator);
        errdefer {
            for (results.items) |*r| r.deinit();
            results.deinit();
        }

        var it = self.index.iterator();
        while (it.next()) |entry| {
            const idx_entry = entry.value_ptr.*;

            // Apply filters
            if (filter.event_types) |event_types| {
                var found = false;
                for (event_types) |t| {
                    if (idx_entry.event_type == t) {
                        found = true;
                        break;
                    }
                }
                if (!found) continue;
            }

            if (filter.actor_id) |id| {
                if (idx_entry.actor_id != id) continue;
            }

            if (filter.session_id) |id| {
                if (idx_entry.session_id == null or idx_entry.session_id.? != id) continue;
            }

            if (filter.start_time) |t| {
                if (idx_entry.timestamp < t) continue;
            }

            if (filter.end_time) |t| {
                if (idx_entry.timestamp > t) continue;
            }

            if (filter.visibility_min) |v| {
                if (@intFromEnum(idx_entry.visibility) < @intFromEnum(v)) continue;
            }

            // Read event payload
            const payload = self.readEventPayload(idx_entry.file_offset) catch |err| switch (err) {
                error.CorruptEvent => continue, // Skip corrupt events
                else => return err,
            };

            try results.append(types.EventResult{
                .header = .{
                    .event_id = entry.key_ptr.*,
                    .event_type = idx_entry.event_type,
                    .timestamp = idx_entry.timestamp,
                    .actor_id = idx_entry.actor_id,
                    .session_id = idx_entry.session_id,
                    .visibility = idx_entry.visibility,
                    .payload_len = @intCast(payload.len),
                },
                .payload = payload,
                .allocator = self.allocator,
            });

            if (filter.limit) |limit| {
                if (results.items.len >= limit) break;
            }
        }

        return try results.toOwnedSlice();
    }

    /// Get event by ID
    pub fn getEvent(self: *Self, event_id: u64) !?types.EventResult {
        const idx_entry = self.index.get(event_id) orelse return null;

        const payload = try self.readEventPayload(idx_entry.file_offset);

        return types.EventResult{
            .header = .{
                .event_id = event_id,
                .event_type = idx_entry.event_type,
                .timestamp = idx_entry.timestamp,
                .actor_id = idx_entry.actor_id,
                .session_id = idx_entry.session_id,
                .visibility = idx_entry.visibility,
                .payload_len = @intCast(payload.len),
            },
            .payload = payload,
            .allocator = self.allocator,
        };
    }

    /// Get events for a specific session
    pub fn getSessionEvents(self: *Self, session_id: u64) ![]types.EventResult {
        return self.queryEvents(.{
            .session_id = session_id,
        });
    }

    /// Get events by actor
    pub fn getActorEvents(self: *Self, actor_id: u64, limit: ?usize) ![]types.EventResult {
        return self.queryEvents(.{
            .actor_id = actor_id,
            .limit = limit,
        });
    }

    /// Time-travel query: get events as of a specific timestamp
    pub fn getEventsAsOf(self: *Self, timestamp: i64) ![]types.EventResult {
        return self.queryEvents(.{
            .end_time = timestamp,
        });
    }

    /// Private: Read event payload from file
    fn readEventPayload(self: *Self, file_offset: u64) ![]u8 {
        var offset = file_offset;

        // Read header
        var header: EventRecordHeader = undefined;
        const header_bytes = std.mem.asBytes(&header);
        const bytes_read = try self.events_file.pread(header_bytes, offset);
        if (bytes_read < @sizeOf(EventRecordHeader)) return error.CorruptEvent;
        offset += @sizeOf(EventRecordHeader);

        // Validate payload size
        if (header.payload_len > self.max_payload_size) return error.PayloadTooLarge;

        // Read payload
        const payload = try self.allocator.alloc(u8, header.payload_len);
        errdefer self.allocator.free(payload);

        const payload_read = try self.events_file.pread(payload, offset);
        if (payload_read < header.payload_len) {
            return error.CorruptEvent;
        }
        offset += header.payload_len;

        // Read and validate trailer
        var trailer: EventRecordTrailer = undefined;
        const trailer_bytes = std.mem.asBytes(&trailer);
        const trailer_read = try self.events_file.pread(trailer_bytes, offset);
        if (trailer_read < @sizeOf(EventRecordTrailer)) return error.CorruptEvent;

        if (trailer.magic != 0x564E5452) return error.CorruptEvent;

        return payload;
    }

    /// Private: Scan events file to find highest event ID
    fn scanHighestEventId(self: *Self) !u64 {
        var max_id: u64 = 0;
        var file_pos: usize = 0;
        const file_size = try self.events_file.getEndPos();

        while (file_pos < file_size) {
            // Read header
            var header: EventRecordHeader = undefined;
            const header_bytes = std.mem.asBytes(&header);
            const bytes_read = try self.events_file.pread(header_bytes, file_pos);
            if (bytes_read < @sizeOf(EventRecordHeader)) break;

            // Validate trailer magic
            const trailer_offset = file_pos + @sizeOf(EventRecordHeader) + header.payload_len;
            var trailer: EventRecordTrailer = undefined;
            const trailer_bytes = std.mem.asBytes(&trailer);
            const trailer_read = try self.events_file.pread(trailer_bytes, trailer_offset);

            if (trailer_read >= @sizeOf(EventRecordTrailer) and trailer.magic == 0x564E5452) {
                if (header.event_id > max_id) {
                    max_id = header.event_id;
                }
                file_pos += @sizeOf(EventRecordHeader) + header.payload_len + @sizeOf(EventRecordTrailer);
            } else {
                // Corrupt record, stop scanning
                break;
            }
        }

        // next_event_id should be max_id + 1
        return max_id + 1;
    }

    /// Private: Load index from index file
    fn loadIndex(self: *Self) !void {
        const index_size = try self.index_file.getEndPos();
        if (index_size == 0) return;

        const entry_size = @sizeOf(u64) + // event_id
            @sizeOf(u64) + // file_offset
            @sizeOf(u16) + // event_type
            @sizeOf(i64) + // timestamp
            @sizeOf(u64) + // actor_id
            @sizeOf(u64) + // session_id (as u64, 0 if null)
            @sizeOf(u8); // visibility

        if (index_size % entry_size != 0) return error.CorruptIndex;

        var offset: usize = 0;
        while (offset < index_size) {
            var event_id: u64 = undefined;
            var file_offset: u64 = undefined;
            var event_type: u16 = undefined;
            var timestamp: i64 = undefined;
            var actor_id: u64 = undefined;
            var session_id_raw: u64 = undefined;
            var visibility: u8 = undefined;

            offset += try self.index_file.preadAll(std.mem.asBytes(&event_id), offset);
            offset += try self.index_file.preadAll(std.mem.asBytes(&file_offset), offset);
            offset += try self.index_file.preadAll(std.mem.asBytes(&event_type), offset);
            offset += try self.index_file.preadAll(std.mem.asBytes(&timestamp), offset);
            offset += try self.index_file.preadAll(std.mem.asBytes(&actor_id), offset);
            offset += try self.index_file.preadAll(std.mem.asBytes(&session_id_raw), offset);
            offset += try self.index_file.preadAll(std.mem.asBytes(&visibility), offset);

            const session_id: ?u64 = if (session_id_raw == 0) null else session_id_raw;

            try self.index.put(event_id, EventIndexEntry{
                .file_offset = file_offset,
                .event_type = @enumFromInt(event_type),
                .timestamp = timestamp,
                .actor_id = actor_id,
                .session_id = session_id,
                .visibility = @enumFromInt(visibility),
            });
        }
    }

    /// Private: Save index to index file
    fn saveIndex(self: *Self) !void {
        try self.index_file.setEndPos(0);
        try self.index_file.seekTo(0);

        var it = self.index.iterator();
        while (it.next()) |entry| {
            const idx_entry = entry.value_ptr.*;

            const session_id_raw = idx_entry.session_id orelse 0;

            // Write all index entry fields directly
            var entry_buf: [31]u8 = undefined; // 8+8+2+8+8+8+1 = 43 bytes actually
            var offset: usize = 0;

            std.mem.writeInt(u64, entry_buf[0..8], entry.key_ptr.*, .little);
            offset += 8;
            std.mem.writeInt(u64, entry_buf[offset..][0..8], idx_entry.file_offset, .little);
            offset += 8;
            std.mem.writeInt(u16, entry_buf[offset..][0..2], @intFromEnum(idx_entry.event_type), .little);
            offset += 2;
            std.mem.writeInt(i64, entry_buf[offset..][0..8], idx_entry.timestamp, .little);
            offset += 8;
            std.mem.writeInt(u64, entry_buf[offset..][0..8], idx_entry.actor_id, .little);
            offset += 8;
            std.mem.writeInt(u64, entry_buf[offset..][0..8], session_id_raw, .little);
            offset += 8;
            std.mem.writeInt(u8, entry_buf[offset..][0..1], @intFromEnum(idx_entry.visibility), .little);

            try self.index_file.writeAll(&entry_buf);
        }

        try self.index_file.sync();
    }

    /// Compact event storage (remove events older than retention period)
    pub fn compact(self: *Self, retain_after_ns: i64) !void {
        var events_to_remove = std.array_list.AlignedManaged(u64, null).init(self.allocator);
        defer events_to_remove.deinit();

        const now = @as(i64, @intCast(std.time.nanoTimestamp()));
        const cutoff = now - retain_after_ns;

        var it = self.index.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.timestamp < cutoff) {
                try events_to_remove.append(entry.key_ptr.*);
            }
        }

        // Remove from index
        for (events_to_remove.items) |event_id| {
            _ = self.index.remove(event_id);
        }

        // Rebuild index and events file
        try self.rebuildStorage();
    }

    /// Rebuild storage from current index (removes gaps)
    fn rebuildStorage(self: *Self) !void {
        const temp_events_path = "northstar_events_temp.dat";
        const temp_index_path = "northstar_events_temp.idx";

        defer {
            std.fs.cwd().deleteFile(temp_events_path) catch {};
            std.fs.cwd().deleteFile(temp_index_path) catch {};
        }

        var temp_events = try std.fs.cwd().createFile(temp_events_path, .{ .read = true });
        defer temp_events.close();

        var temp_index = try std.fs.cwd().createFile(temp_index_path, .{ .read = true });
        defer temp_index.close();

        var new_index = std.AutoHashMap(u64, EventIndexEntry).init(self.allocator);
        errdefer new_index.deinit();

        var it = self.index.iterator();
        while (it.next()) |entry| {
            const idx_entry = entry.value_ptr.*;
            const event_id = entry.key_ptr.*;

            // Read event from current file
            const payload = try self.readEventPayload(idx_entry.file_offset);
            defer self.allocator.free(payload);

            // Write to temp file
            const new_offset = try temp_events.getEndPos();

            var header = EventRecordHeader{
                .event_id = event_id,
                .event_type = @intFromEnum(idx_entry.event_type),
                .timestamp = idx_entry.timestamp,
                .actor_id = idx_entry.actor_id,
                .payload_len = @intCast(payload.len),
            };

            _ = try temp_events.writeAll(std.mem.asBytes(&header));
            _ = try temp_events.writeAll(payload);

            var trailer = EventRecordTrailer{
                .magic = 0x564E5452,
                .total_len = @intCast(EVENT_HEADER_SIZE + payload.len + EVENT_TRAILER_SIZE),
            };
            _ = try temp_events.writeAll(std.mem.asBytes(&trailer));

            try new_index.put(event_id, EventIndexEntry{
                .file_offset = new_offset,
                .event_type = idx_entry.event_type,
                .timestamp = idx_entry.timestamp,
                .actor_id = idx_entry.actor_id,
                .session_id = idx_entry.session_id,
                .visibility = idx_entry.visibility,
            });
        }

        // Sync and close temp files
        try temp_events.sync();
        try temp_index.sync();

        // Replace original files
        try self.events_file.close();
        try self.index_file.close();

        try std.fs.cwd().rename(temp_events_path, self.events_file.getName() orelse "northstar_events.dat");
        try std.fs.cwd().rename(temp_index_path, self.index_file.getName() orelse "northstar_events.idx");

        // Reopen files
        self.events_file = try std.fs.cwd().openFile(self.events_file.getName() orelse "northstar_events.dat", .{ .mode = .read_write });
        self.index_file = try std.fs.cwd().openFile(self.index_file.getName() orelse "northstar_events.idx", .{ .mode = .read_write });

        // Replace index
        self.index.deinit();
        self.index = new_index;
    }
};

test "EventStore basic append and query" {
    const allocator = std.testing.allocator;
    const config = EventStore.Config{
        .events_path = "test_events.dat",
        .index_path = "test_events.idx",
    };

    defer std.fs.cwd().deleteFile(config.events_path) catch {};
    defer std.fs.cwd().deleteFile(config.index_path) catch {};

    var store = try EventStore.open(allocator, config);
    defer store.deinit();

    // Append agent session event
    const timestamp = @as(i64, @intCast(std.time.nanoTimestamp()));
    const header = types.EventHeader{
        .event_id = 0,
        .event_type = .agent_session_started,
        .timestamp = timestamp,
        .actor_id = 42,
        .session_id = 1,
        .visibility = .private,
        .payload_len = 0,
    };

    const payload = "test session data";
    const event_id = try store.appendEvent(header, payload);

    try std.testing.expectEqual(@as(u64, 0), event_id);

    // Query events
    const results = try store.queryEvents(.{
        .actor_id = 42,
    });

    defer {
        for (results) |*r| r.deinit();
        allocator.free(results);
    }

    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqual(@as(u64, 42), results[0].header.actor_id);
}

test "EventStore session events" {
    const allocator = std.testing.allocator;
    const config = EventStore.Config{
        .events_path = "test_session_events.dat",
        .index_path = "test_session_events.idx",
    };

    defer std.fs.cwd().deleteFile(config.events_path) catch {};
    defer std.fs.cwd().deleteFile(config.index_path) catch {};

    var store = try EventStore.open(allocator, config);
    defer store.deinit();

    const timestamp = @as(i64, @intCast(std.time.nanoTimestamp()));

    // Create session events
    const header1 = types.EventHeader{
        .event_id = 0,
        .event_type = .agent_session_started,
        .timestamp = timestamp,
        .actor_id = 1,
        .session_id = 100,
        .visibility = .private,
        .payload_len = 0,
    };
    _ = try store.appendEvent(header1, "session start");

    const header2 = types.EventHeader{
        .event_id = 0,
        .event_type = .agent_operation,
        .timestamp = timestamp + 1,
        .actor_id = 1,
        .session_id = 100,
        .visibility = .private,
        .payload_len = 0,
    };
    _ = try store.appendEvent(header2, "operation data");

    // Query by session
    const session_events = try store.getSessionEvents(100);

    defer {
        for (session_events) |*r| r.deinit();
        allocator.free(session_events);
    }

    try std.testing.expectEqual(@as(usize, 2), session_events.len);
}

test "EventStore persistence across reopen" {
    const allocator = std.testing.allocator;
    const config = EventStore.Config{
        .events_path = "test_persist_events.dat",
        .index_path = "test_persist_events.idx",
    };

    defer std.fs.cwd().deleteFile(config.events_path) catch {};
    defer std.fs.cwd().deleteFile(config.index_path) catch {};

    {
        var store = try EventStore.open(allocator, config);
        defer store.deinit();

        const timestamp = @as(i64, @intCast(std.time.nanoTimestamp()));
        const header = types.EventHeader{
            .event_id = 0,
            .event_type = .review_note,
            .timestamp = timestamp,
            .actor_id = 99,
            .session_id = 5,
            .visibility = .team,
            .payload_len = 0,
        };

        _ = try store.appendEvent(header, "review note payload");
    }

    // Reopen and verify
    var store = try EventStore.open(allocator, config);
    defer store.deinit();

    const events = try store.getActorEvents(99, null);

    defer {
        for (events) |*r| r.deinit();
        allocator.free(events);
    }

    try std.testing.expectEqual(@as(usize, 1), events.len);
    try std.testing.expectEqual(@as(u64, 99), events[0].header.actor_id);
}
