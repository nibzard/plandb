//! Code Review Cartridge for Review & Observability system
//!
//! Provides structured storage and retrieval of review notes,
//! linking them to commits, files, symbols, and other code artifacts.

const std = @import("std");
const events = @import("../events/index.zig");

/// Code Review Cartridge
///
/// Stores and retrieves review notes linked to code artifacts:
/// - Commits (by commit hash)
/// - Files (by file path)
/// - Symbols (by fully qualified symbol name)
/// - PR-like objects (synthetic IDs)
pub const CodeReviewCartridge = struct {
    allocator: std.mem.Allocator,
    event_manager: *events.EventManager,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, event_manager: *events.EventManager) Self {
        return Self{
            .allocator = allocator,
            .event_manager = event_manager,
        };
    }

    /// Add a review note for a target
    pub fn addReviewNote(
        self: *Self,
        author: u64,
        target_type: []const u8,
        target_id: []const u8,
        note_text: []const u8,
        visibility: events.types.EventVisibility,
        references: [][]const u8,
    ) !u64 {
        // Record via event manager
        return self.event_manager.recordReviewNote(
            author,
            target_type,
            target_id,
            note_text,
            visibility,
            references,
        );
    }

    /// Get review notes for a target
    pub fn getReviewNotes(
        self: *Self,
        target_type: []const u8,
        target_id: []const u8,
    ) ![]ReviewNote {
        // Query all review notes and filter
        const all_notes = try self.event_manager.query(.{
            .event_types = &[_]events.types.EventType{.review_note},
        });

        var filtered = std.ArrayList(ReviewNote).init(self.allocator);
        errdefer {
            for (filtered.items) |*n| n.deinit(self.allocator);
            filtered.deinit();
        }

        for (all_notes) |event_result| {
            defer event_result.deinit();

            // Deserialize review note from payload
            // For now, use a simple format: target_type\0target_id\0note_text
            const payload = event_result.payload;

            var parts = std.mem.splitScalar(u8, payload, 0);
            const note_target_type = parts.first() orelse continue;

            // Check if this note matches our target
            if (!std.mem.eql(u8, target_type, note_target_type)) continue;

            const note_target_id = parts.next() orelse continue;
            if (!std.mem.eql(u8, target_id, note_target_id)) continue;

            const note_text = parts.rest();

            var note = ReviewNote{
                .event_id = event_result.header.event_id,
                .author = event_result.header.actor_id,
                .target_type = try self.allocator.dupe(u8, note_target_type),
                .target_id = try self.allocator.dupe(u8, note_target_id),
                .note_text = try self.allocator.dupe(u8, note_text),
                .visibility = event_result.header.visibility,
                .timestamp = event_result.header.timestamp,
                .references = &[_][]const u8{},
            };
            errdefer note.deinit(self.allocator);

            try filtered.append(note);
        }

        self.allocator.free(all_notes);
        return filtered.toOwnedSlice();
    }

    /// Get review notes for a commit
    pub fn getCommitReviews(
        self: *Self,
        commit_hash: []const u8,
    ) ![]ReviewNote {
        return self.getReviewNotes("commit", commit_hash);
    }

    /// Get review notes for a file
    pub fn getFileReviews(
        self: *Self,
        file_path: []const u8,
    ) ![]ReviewNote {
        return self.getReviewNotes("file", file_path);
    }

    /// Get review notes for a symbol
    pub fn getSymbolReviews(
        self: *Self,
        symbol_name: []const u8,
    ) ![]ReviewNote {
        return self.getReviewNotes("symbol", symbol_name);
    }

    /// Get review notes by author
    pub fn getReviewsByAuthor(
        self: *Self,
        author_id: u64,
        limit: ?usize,
    ) ![]ReviewNote {
        const events = try self.event_manager.getActorEvents(author_id, limit);
        defer {
            for (events) |*e| e.deinit();
            self.allocator.free(events);
        }

        var notes = std.ArrayList(ReviewNote).init(self.allocator);
        errdefer {
            for (notes.items) |*n| n.deinit(self.allocator);
            notes.deinit();
        }

        for (events) |event_result| {
            if (event_result.header.event_type != .review_note) continue;

            const payload = event_result.payload;
            var parts = std.mem.splitScalar(u8, payload, 0);

            const target_type = parts.first() orelse continue;
            const target_id = parts.next() orelse continue;
            const note_text = parts.rest();

            var note = ReviewNote{
                .event_id = event_result.header.event_id,
                .author = event_result.header.actor_id,
                .target_type = try self.allocator.dupe(u8, target_type),
                .target_id = try self.allocator.dupe(u8, target_id),
                .note_text = try self.allocator.dupe(u8, note_text),
                .visibility = event_result.header.visibility,
                .timestamp = event_result.header.timestamp,
                .references = &[_][]const u8{},
            };
            errdefer note.deinit(self.allocator);

            try notes.append(note);
        }

        return notes.toOwnedSlice();
    }

    /// Get all review notes (with optional limit)
    pub fn getAllReviews(
        self: *Self,
        limit: ?usize,
    ) ![]ReviewNote {
        const events_results = try self.event_manager.query(.{
            .event_types = &[_]events.types.EventType{.review_note},
            .limit = limit,
        });

        var notes = std.ArrayList(ReviewNote).init(self.allocator);
        errdefer {
            for (notes.items) |*n| n.deinit(self.allocator);
            notes.deinit();
        }

        for (events_results) |event_result| {
            defer event_result.deinit();

            const payload = event_result.payload;
            var parts = std.mem.splitScalar(u8, payload, 0);

            const target_type = parts.first() orelse continue;
            const target_id = parts.next() orelse continue;
            const note_text = parts.rest();

            var note = ReviewNote{
                .event_id = event_result.header.event_id,
                .author = event_result.header.actor_id,
                .target_type = try self.allocator.dupe(u8, target_type),
                .target_id = try self.allocator.dupe(u8, target_id),
                .note_text = try self.allocator.dupe(u8, note_text),
                .visibility = event_result.header.visibility,
                .timestamp = event_result.header.timestamp,
                .references = &[_][]const u8{},
            };
            errdefer note.deinit(self.allocator);

            try notes.append(note);
        }

        self.allocator.free(events_results);
        return notes.toOwnedSlice();
    }

    /// Get review notes with specific visibility
    pub fn getReviewsByVisibility(
        self: *Self,
        min_visibility: events.types.EventVisibility,
        limit: ?usize,
    ) ![]ReviewNote {
        const events_results = try self.event_manager.query(.{
            .event_types = &[_]events.types.EventType{.review_note},
            .visibility_min = min_visibility,
            .limit = limit,
        });

        var notes = std.ArrayList(ReviewNote).init(self.allocator);
        errdefer {
            for (notes.items) |*n| n.deinit(self.allocator);
            notes.deinit();
        }

        for (events_results) |event_result| {
            defer event_result.deinit();

            const payload = event_result.payload;
            var parts = std.mem.splitScalar(u8, payload, 0);

            const target_type = parts.first() orelse continue;
            const target_id = parts.next() orelse continue;
            const note_text = parts.rest();

            var note = ReviewNote{
                .event_id = event_result.header.event_id,
                .author = event_result.header.actor_id,
                .target_type = try self.allocator.dupe(u8, target_type),
                .target_id = try self.allocator.dupe(u8, target_id),
                .note_text = try self.allocator.dupe(u8, note_text),
                .visibility = event_result.header.visibility,
                .timestamp = event_result.header.timestamp,
                .references = &[_][]const u8{},
            };
            errdefer note.deinit(self.allocator);

            try notes.append(note);
        }

        self.allocator.free(events_results);
        return notes.toOwnedSlice();
    }

    /// Get review notes within a time range
    pub fn getReviewsInTimeRange(
        self: *Self,
        start_time: i64,
        end_time: i64,
        limit: ?usize,
    ) ![]ReviewNote {
        const events_results = try self.event_manager.query(.{
            .event_types = &[_]events.types.EventType{.review_note},
            .start_time = start_time,
            .end_time = end_time,
            .limit = limit,
        });

        var notes = std.ArrayList(ReviewNote).init(self.allocator);
        errdefer {
            for (notes.items) |*n| n.deinit(self.allocator);
            notes.deinit();
        }

        for (events_results) |event_result| {
            defer event_result.deinit();

            const payload = event_result.payload;
            var parts = std.mem.splitScalar(u8, payload, 0);

            const target_type = parts.first() orelse continue;
            const target_id = parts.next() orelse continue;
            const note_text = parts.rest();

            var note = ReviewNote{
                .event_id = event_result.header.event_id,
                .author = event_result.header.actor_id,
                .target_type = try self.allocator.dupe(u8, target_type),
                .target_id = try self.allocator.dupe(u8, target_id),
                .note_text = try self.allocator.dupe(u8, note_text),
                .visibility = event_result.header.visibility,
                .timestamp = event_result.header.timestamp,
                .references = &[_][]const u8{},
            };
            errdefer note.deinit(self.allocator);

            try notes.append(note);
        }

        self.allocator.free(events_results);
        return notes.toOwnedSlice();
    }

    /// Count review notes by target type
    pub fn countReviewsByTargetType(
        self: *Self,
        target_type: []const u8,
    ) !usize {
        const events_results = try self.event_manager.query(.{
            .event_types = &[_]events.types.EventType{.review_note},
        });
        defer {
            for (events_results) |*e| e.deinit();
            self.allocator.free(events_results);
        }

        var count: usize = 0;
        for (events_results) |event_result| {
            const payload = event_result.payload;
            const end_idx = std.mem.indexOfScalar(u8, payload, 0) orelse continue;
            const event_target_type = payload[0..end_idx];

            if (std.mem.eql(u8, target_type, event_target_type)) {
                count += 1;
            }
        }

        return count;
    }
};

/// Review note data structure
pub const ReviewNote = struct {
    event_id: u64,
    author: u64,
    target_type: []const u8,
    target_id: []const u8,
    note_text: []const u8,
    visibility: events.types.EventVisibility,
    timestamp: i64,
    references: [][]const u8,

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

test "CodeReviewCartridge add and retrieve review" {
    const allocator = std.testing.allocator;

    const config = events.storage.EventStore.Config{
        .events_path = "test_review_cart_events.dat",
        .index_path = "test_review_cart_events.idx",
    };

    defer {
        std.fs.cwd().deleteFile(config.events_path) catch {};
        std.fs.cwd().deleteFile(config.index_path) catch {};
    };

    var store = try events.storage.EventStore.open(allocator, config);
    defer store.deinit();

    var event_manager = events.EventManager.init(allocator, &store);
    var cartridge = CodeReviewCartridge.init(allocator, &event_manager);

    // Add a review note
    const event_id = try cartridge.addReviewNote(
        42,
        "commit",
        "abc123",
        "This commit introduces a potential race condition",
        .team,
        &[_][]const u8{},
    );

    try std.testing.expect(event_id >= 0);

    // Retrieve review notes for the commit
    const notes = try cartridge.getCommitReviews("abc123");

    defer {
        for (notes) |*n| n.deinit(allocator);
        allocator.free(notes);
    }

    try std.testing.expectEqual(@as(usize, 1), notes.len);
    try std.testing.expectEqual(@as(u64, 42), notes[0].author);
    try std.testing.expectEqualStrings("This commit introduces a potential race condition", notes[0].note_text);
}

test "CodeReviewCartridge count by target type" {
    const allocator = std.testing.allocator;

    const config = events.storage.EventStore.Config{
        .events_path = "test_review_count_events.dat",
        .index_path = "test_review_count_events.idx",
    };

    defer {
        std.fs.cwd().deleteFile(config.events_path) catch {};
        std.fs.cwd().deleteFile(config.index_path) catch {};
    };

    var store = try events.storage.EventStore.open(allocator, config);
    defer store.deinit();

    var event_manager = events.EventManager.init(allocator, &store);
    var cartridge = CodeReviewCartridge.init(allocator, &event_manager);

    // Add multiple reviews
    _ = try cartridge.addReviewNote(1, "commit", "abc", "note1", .team, &[_][]const u8{});
    _ = try cartridge.addReviewNote(1, "commit", "def", "note2", .team, &[_][]const u8{});
    _ = try cartridge.addReviewNote(1, "file", "src/main.zig", "note3", .team, &[_][]const u8{});

    const commit_count = try cartridge.countReviewsByTargetType("commit");
    const file_count = try cartridge.countReviewsByTargetType("file");

    try std.testing.expectEqual(@as(usize, 2), commit_count);
    try std.testing.expectEqual(@as(usize, 1), file_count);
}

test "CodeReviewCartridge reviews by author" {
    const allocator = std.testing.allocator;

    const config = events.storage.EventStore.Config{
        .events_path = "test_review_author_events.dat",
        .index_path = "test_review_author_events.idx",
    };

    defer {
        std.fs.cwd().deleteFile(config.events_path) catch {};
        std.fs.cwd().deleteFile(config.index_path) catch {};
    };

    var store = try events.storage.EventStore.open(allocator, config);
    defer store.deinit();

    var event_manager = events.EventManager.init(allocator, &store);
    var cartridge = CodeReviewCartridge.init(allocator, &event_manager);

    // Add reviews from different authors
    _ = try cartridge.addReviewNote(1, "commit", "abc", "note from agent 1", .team, &[_][]const u8{});
    _ = try cartridge.addReviewNote(2, "commit", "def", "note from agent 2", .team, &[_][]const u8{});
    _ = try cartridge.addReviewNote(1, "file", "main.zig", "another from agent 1", .team, &[_][]const u8{});

    // Get reviews by author 1
    const notes = try cartridge.getReviewsByAuthor(1, null);

    defer {
        for (notes) |*n| n.deinit(allocator);
        allocator.free(notes);
    }

    try std.testing.expectEqual(@as(usize, 2), notes.len);
    for (notes) |note| {
        try std.testing.expectEqual(@as(u64, 1), note.author);
    }
}
