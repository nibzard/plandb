//! Document Version History Cartridge Implementation
//!
//! Implements diff storage with annotated history for documents according to
//! spec/structured_memory_v1.md
//!
//! This cartridge supports:
//! - Annotated diffs per document (line-based + token-based)
//! - Change metadata: author, intent, severity, linked issues
//! - Binary file handling (hash-based, no diff)
//! - Parent-child relationship tracking for branching

const std = @import("std");
const format = @import("format.zig");
const ArrayListManaged = std.ArrayListUnmanaged;

// ==================== Diff Types ====================

/// Type of diff storage
pub const DiffType = enum(u8) {
    /// Line-based diff for text files
    line = 1,
    /// Token-based diff for more granular changes
    token = 2,
    /// Binary file (hash-based, no diff)
    binary = 3,
    /// Full file replacement
    full = 4,

    pub fn fromUint(v: u8) !DiffType {
        return std.meta.intToEnum(DiffType, v);
    }
};

/// Change intent classification
pub const ChangeIntent = enum(u8) {
    /// Bug fix
    bugfix = 1,
    /// New feature
    feature = 2,
    /// Refactoring
    refactor = 3,
    /// Documentation
    docs = 4,
    /// Test changes
    tests = 5,
    /// Performance optimization
    perf = 6,
    /// Security fix
    security = 7,
    /// Style/formatting
    style = 8,
    /// Other/unknown
    other = 9,

    pub fn fromUint(v: u8) !ChangeIntent {
        return std.meta.intToEnum(ChangeIntent, v);
    }
};

/// Change severity level
pub const ChangeSeverity = enum(u8) {
    /// Trivial change
    trivial = 1,
    /// Minor change
    minor = 2,
    /// Moderate change
    moderate = 3,
    /// Major change
    major = 4,
    /// Critical change
    critical = 5,

    pub fn fromUint(v: u8) !ChangeSeverity {
        return std.meta.intToEnum(ChangeSeverity, v);
    }
};

// ==================== Diff Operations ====================

/// Single diff operation (hunk)
pub const DiffOp = struct {
    /// Start line number (0-indexed)
    start_line: u32,
    /// Number of lines removed
    lines_removed: u32,
    /// Number of lines added
    lines_added: u32,
    /// Removed lines content
    removed: []const u8,
    /// Added lines content
    added: []const u8,

    /// Calculate size of this diff op
    pub fn size(self: DiffOp) usize {
        return 4 + 4 + 4 + // start_line, lines_removed, lines_added
            4 + self.removed.len + // removed length + data
            4 + self.added.len; // added length + data
    }

    /// Free diff op resources
    pub fn deinit(self: DiffOp, allocator: std.mem.Allocator) void {
        allocator.free(self.removed);
        allocator.free(self.added);
    }
};

// ==================== Document Version ====================

/// Single document version with diff and metadata
pub const DocumentVersion = struct {
    /// Unique version identifier
    version_id: []const u8,
    /// Parent version ID (null for initial version)
    parent_version_id: ?[]const u8,
    /// Branch name
    branch: []const u8,
    /// Commit hash/ID
    commit_id: []const u8,
    /// Author who made this change
    author: []const u8,
    /// Timestamp of change
    timestamp: i64,
    /// Change message
    message: []const u8,
    /// Type of diff
    diff_type: DiffType,
    /// Diff operations
    diffs: ArrayListManaged(DiffOp),
    /// Change intent classification
    intent: ChangeIntent,
    /// Change severity
    severity: ChangeSeverity,
    /// Linked issue IDs
    linked_issues: ArrayListManaged([]const u8),
    /// File hash (for binary files)
    file_hash: [32]u8,

    /// Create new document version
    pub fn init(allocator: std.mem.Allocator, version_id: []const u8, author: []const u8) !DocumentVersion {
        return DocumentVersion{
            .version_id = try allocator.dupe(u8, version_id),
            .parent_version_id = null,
            .branch = try allocator.dupe(u8, "main"),
            .commit_id = try allocator.dupe(u8, ""),
            .author = try allocator.dupe(u8, author),
            .timestamp = std.time.timestamp(),
            .message = try allocator.dupe(u8, ""),
            .diff_type = .line,
            .diffs = .{},
            .intent = .other,
            .severity = .moderate,
            .linked_issues = .{},
            .file_hash = [_]u8{0} ** 32,
        };
    }

    pub fn deinit(self: *DocumentVersion, allocator: std.mem.Allocator) void {
        allocator.free(self.version_id);
        if (self.parent_version_id) |p| allocator.free(p);
        allocator.free(self.branch);
        allocator.free(self.commit_id);
        allocator.free(self.author);
        allocator.free(self.message);
        for (self.diffs.items) |*diff| diff.deinit(allocator);
        self.diffs.deinit(allocator);
        for (self.linked_issues.items) |issue| allocator.free(issue);
        self.linked_issues.deinit(allocator);
    }

    /// Add diff operation
    pub fn addDiff(self: *DocumentVersion, allocator: std.mem.Allocator, diff: DiffOp) !void {
        const owned_diff = DiffOp{
            .start_line = diff.start_line,
            .lines_removed = diff.lines_removed,
            .lines_added = diff.lines_added,
            .removed = try allocator.dupe(u8, diff.removed),
            .added = try allocator.dupe(u8, diff.added),
        };
        try self.diffs.append(allocator, owned_diff);
    }

    /// Add linked issue
    pub fn addLinkedIssue(self: *DocumentVersion, allocator: std.mem.Allocator, issue_id: []const u8) !void {
        const issue = try allocator.dupe(u8, issue_id);
        try self.linked_issues.append(allocator, issue);
    }
};

// ==================== Document History ====================

/// Complete document history with version tracking
pub const DocumentHistory = struct {
    allocator: std.mem.Allocator,
    /// Document path/identifier
    document_path: []const u8,
    /// All versions of this document
    versions: ArrayListManaged(*DocumentVersion),
    /// Branches mapping (branch name -> latest version ID)
    branches: std.StringHashMap([]const u8),

    /// Create new document history
    pub fn init(allocator: std.mem.Allocator, document_path: []const u8) !DocumentHistory {
        const path_copy = try allocator.dupe(u8, document_path);
        return DocumentHistory{
            .allocator = allocator,
            .document_path = path_copy,
            .versions = .{},
            .branches = std.StringHashMap([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *DocumentHistory) void {
        self.allocator.free(self.document_path);
        for (self.versions.items) |version| {
            version.deinit(self.allocator);
            self.allocator.destroy(version);
        }
        self.versions.deinit(self.allocator);

        // Free branch values
        var it = self.branches.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.branches.deinit();
    }

    /// Add new version to history
    pub fn addVersion(self: *DocumentHistory, version: *DocumentVersion) !void {
        try self.versions.append(self.allocator, version);

        // Update branch pointer
        const entry = try self.branches.getOrPut(version.branch);
        if (entry.found_existing) {
            self.allocator.free(entry.value_ptr.*);
        } else {
            entry.key_ptr.* = try self.allocator.dupe(u8, version.branch);
        }
        entry.value_ptr.* = try self.allocator.dupe(u8, version.version_id);
    }

    /// Get version by ID
    pub fn getVersion(self: *const DocumentHistory, version_id: []const u8) ?*DocumentVersion {
        for (self.versions.items) |version| {
            if (std.mem.eql(u8, version.version_id, version_id)) {
                return version;
            }
        }
        return null;
    }

    /// Get latest version for a branch
    pub fn getLatestVersion(self: *const DocumentHistory, branch: []const u8) ?*DocumentVersion {
        const version_id = self.branches.get(branch) orelse return null;
        return self.getVersion(version_id);
    }

    /// Get all versions between two versions (inclusive)
    pub fn getVersionsBetween(self: *const DocumentHistory, from_version: []const u8, to_version: []const u8) !ArrayListManaged(*DocumentVersion) {
        var results = ArrayListManaged(*DocumentVersion){};

        var found_from = false;
        for (self.versions.items) |version| {
            if (!found_from) {
                if (std.mem.eql(u8, version.version_id, from_version)) {
                    found_from = true;
                }
                try results.append(self.allocator, version);
            } else {
                try results.append(self.allocator, version);
                if (std.mem.eql(u8, version.version_id, to_version)) {
                    break;
                }
            }
        }

        return results;
    }
};

// ==================== Document History Index ====================

/// Index for querying document histories
pub const DocumentHistoryIndex = struct {
    allocator: std.mem.Allocator,
    /// Map from document path to history
    histories: std.StringHashMap(*DocumentHistory),
    /// Map from author to list of document paths they modified
    author_index: std.StringHashMap(ArrayListManaged([]const u8)),
    /// Map from commit ID to list of document paths
    commit_index: std.StringHashMap(ArrayListManaged([]const u8)),
    /// Map from intent to list of versions
    intent_index: std.StringHashMap(ArrayListManaged(*DocumentVersion)),
    /// Total versions stored
    total_versions: u64,

    /// Create new document history index
    pub fn init(allocator: std.mem.Allocator) DocumentHistoryIndex {
        return DocumentHistoryIndex{
            .allocator = allocator,
            .histories = std.StringHashMap(*DocumentHistory).init(allocator),
            .author_index = std.StringHashMap(ArrayListManaged([]const u8)).init(allocator),
            .commit_index = std.StringHashMap(ArrayListManaged([]const u8)).init(allocator),
            .intent_index = std.StringHashMap(ArrayListManaged(*DocumentVersion)).init(allocator),
            .total_versions = 0,
        };
    }

    pub fn deinit(self: *DocumentHistoryIndex) void {
        // Free all histories
        var it = self.histories.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.*.deinit();
            self.allocator.destroy(entry.value_ptr);
        }
        self.histories.deinit();

        // Free author index
        var author_it = self.author_index.iterator();
        while (author_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            for (entry.value_ptr.items) |path| self.allocator.free(path);
            entry.value_ptr.deinit(self.allocator);
        }
        self.author_index.deinit();

        // Free commit index
        var commit_it = self.commit_index.iterator();
        while (commit_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            for (entry.value_ptr.items) |path| self.allocator.free(path);
            entry.value_ptr.deinit(self.allocator);
        }
        self.commit_index.deinit();

        // Free intent index (versions are owned by histories)
        var intent_it = self.intent_index.iterator();
        while (intent_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(self.allocator);
        }
        self.intent_index.deinit();
    }

    /// Add document version to index
    pub fn addVersion(self: *DocumentHistoryIndex, document_path: []const u8, version: *DocumentVersion) !void {
        // Get or create document history
        const entry = try self.histories.getOrPut(document_path);
        if (!entry.found_existing) {
            entry.key_ptr.* = try self.allocator.dupe(u8, document_path);
            const history = try self.allocator.create(DocumentHistory);
            history.* = try DocumentHistory.init(self.allocator, document_path);
            entry.value_ptr.* = history;
        }

        // Add version to history
        try entry.value_ptr.*.addVersion(version);

        // Update author index
        const author_entry = try self.author_index.getOrPut(version.author);
        if (!author_entry.found_existing) {
            author_entry.key_ptr.* = try self.allocator.dupe(u8, version.author);
            author_entry.value_ptr.* = .{};
        }
        const path_copy = try self.allocator.dupe(u8, document_path);
        try author_entry.value_ptr.append(self.allocator, path_copy);

        // Update commit index
        const commit_entry = try self.commit_index.getOrPut(version.commit_id);
        if (!commit_entry.found_existing) {
            commit_entry.key_ptr.* = try self.allocator.dupe(u8, version.commit_id);
            commit_entry.value_ptr.* = .{};
        }
        const path_copy2 = try self.allocator.dupe(u8, document_path);
        try commit_entry.value_ptr.append(self.allocator, path_copy2);

        // Update intent index
        const intent_str = @tagName(version.intent);
        const intent_entry = try self.intent_index.getOrPut(intent_str);
        if (!intent_entry.found_existing) {
            intent_entry.key_ptr.* = try self.allocator.dupe(u8, intent_str);
            intent_entry.value_ptr.* = .{};
        }
        try intent_entry.value_ptr.append(self.allocator, version);

        self.total_versions += 1;
    }

    /// Query documents modified by author
    pub fn queryByAuthor(self: *const DocumentHistoryIndex, author: []const u8) !ArrayListManaged([]const u8) {
        var results = ArrayListManaged([]const u8){};

        if (self.author_index.get(author)) |paths| {
            for (paths.items) |path| {
                try results.append(self.allocator, try self.allocator.dupe(u8, path));
            }
        }

        return results;
    }

    /// Query documents with specific intent
    pub fn queryByIntent(self: *const DocumentHistoryIndex, intent: ChangeIntent) !ArrayListManaged(*DocumentVersion) {
        var results = ArrayListManaged(*DocumentVersion){};

        const intent_str = @tagName(intent);
        if (self.intent_index.get(intent_str)) |versions| {
            for (versions.items) |version| {
                try results.append(self.allocator, version);
            }
        }

        return results;
    }

    /// Get full version history for a document
    pub fn getHistory(self: *const DocumentHistoryIndex, document_path: []const u8) ?*DocumentHistory {
        return self.histories.get(document_path);
    }

    /// Query what changed between two versions
    pub fn queryDiff(self: *const DocumentHistoryIndex, document_path: []const u8, from_version: []const u8, to_version: []const u8) !ArrayListManaged(DiffOp) {
        var results = ArrayListManaged(DiffOp){};

        const history = self.histories.get(document_path) orelse return results;

        var found_from = false;
        for (history.versions.items) |version| {
            if (std.mem.eql(u8, version.version_id, from_version)) {
                found_from = true;
            }

            if (found_from) {
                // Add all diffs from this version
                for (version.diffs.items) |diff| {
                    const owned_diff = DiffOp{
                        .start_line = diff.start_line,
                        .lines_removed = diff.lines_removed,
                        .lines_added = diff.lines_added,
                        .removed = try self.allocator.dupe(u8, diff.removed),
                        .added = try self.allocator.dupe(u8, diff.added),
                    };
                    try results.append(self.allocator, owned_diff);
                }

                if (std.mem.eql(u8, version.version_id, to_version)) {
                    break;
                }
            }
        }

        return results;
    }
};

// ==================== Document History Cartridge ====================

/// Document history cartridge with diff storage
pub const DocumentHistoryCartridge = struct {
    allocator: std.mem.Allocator,
    header: format.CartridgeHeader,
    /// Document history index
    index: DocumentHistoryIndex,

    /// Create new document history cartridge
    pub fn init(allocator: std.mem.Allocator, source_txn_id: u64) !DocumentHistoryCartridge {
        const header = format.CartridgeHeader.init(.document_history, source_txn_id);
        return DocumentHistoryCartridge{
            .allocator = allocator,
            .header = header,
            .index = DocumentHistoryIndex.init(allocator),
        };
    }

    pub fn deinit(self: *DocumentHistoryCartridge) void {
        self.index.deinit();
    }

    /// Add document version to the cartridge
    pub fn addVersion(self: *DocumentHistoryCartridge, document_path: []const u8, version: *DocumentVersion) !void {
        try self.index.addVersion(document_path, version);
        self.header.entry_count += 1;
    }

    /// Query documents modified by author
    pub fn queryByAuthor(self: *const DocumentHistoryCartridge, author: []const u8) !ArrayListManaged([]const u8) {
        return self.index.queryByAuthor(author);
    }

    /// Query documents with specific intent
    pub fn queryByIntent(self: *const DocumentHistoryCartridge, intent: ChangeIntent) !ArrayListManaged(*DocumentVersion) {
        return self.index.queryByIntent(intent);
    }

    /// Get full history for a document
    pub fn getHistory(self: *const DocumentHistoryCartridge, document_path: []const u8) ?*DocumentHistory {
        return self.index.getHistory(document_path);
    }

    /// Query diff between two versions
    pub fn queryDiff(self: *const DocumentHistoryCartridge, document_path: []const u8, from_version: []const u8, to_version: []const u8) !ArrayListManaged(DiffOp) {
        return self.index.queryDiff(document_path, from_version, to_version);
    }
};

// ==================== Tests ====================

test "DiffType.fromUint" {
    const dt = try DiffType.fromUint(1);
    try std.testing.expectEqual(DiffType.line, dt);
}

test "ChangeIntent.fromUint" {
    const intent = try ChangeIntent.fromUint(1);
    try std.testing.expectEqual(ChangeIntent.bugfix, intent);
}

test "DocumentVersion.init and addDiff" {
    var version = try DocumentVersion.init(std.testing.allocator, "v1", "alice");
    defer version.deinit(std.testing.allocator);

    const diff = DiffOp{
        .start_line = 10,
        .lines_removed = 2,
        .lines_added = 3,
        .removed = "old line 1\nold line 2\n",
        .added = "new line 1\nnew line 2\nnew line 3\n",
    };

    try version.addDiff(std.testing.allocator, diff);

    try std.testing.expectEqual(@as(usize, 1), version.diffs.items.len);
}

test "DocumentVersion.addLinkedIssue" {
    var version = try DocumentVersion.init(std.testing.allocator, "v1", "alice");
    defer version.deinit(std.testing.allocator);

    try version.addLinkedIssue(std.testing.allocator, "ISSUE-123");
    try version.addLinkedIssue(std.testing.allocator, "ISSUE-456");

    try std.testing.expectEqual(@as(usize, 2), version.linked_issues.items.len);
}

test "DocumentHistory.init and addVersion" {
    var history = try DocumentHistory.init(std.testing.allocator, "src/main.zig");
    defer history.deinit();

    const version1 = try std.testing.allocator.create(DocumentVersion);
    version1.* = try DocumentVersion.init(std.testing.allocator, "v1", "alice");

    try history.addVersion(version1);

    try std.testing.expectEqual(@as(usize, 1), history.versions.items.len);
}

test "DocumentHistory.getLatestVersion" {
    var history = try DocumentHistory.init(std.testing.allocator, "src/main.zig");
    defer history.deinit();

    const version1 = try std.testing.allocator.create(DocumentVersion);
    version1.* = try DocumentVersion.init(std.testing.allocator, "v1", "alice");
    // branch is already "main" from init

    const version2 = try std.testing.allocator.create(DocumentVersion);
    version2.* = try DocumentVersion.init(std.testing.allocator, "v2", "bob");
    // branch is already "main" from init

    try history.addVersion(version1);
    try history.addVersion(version2);

    const latest = history.getLatestVersion("main");
    try std.testing.expect(latest != null);
    try std.testing.expectEqualStrings("v2", latest.?.version_id);
}

test "DocumentHistoryIndex.init and addVersion" {
    var index = DocumentHistoryIndex.init(std.testing.allocator);
    defer index.deinit();

    const version = try std.testing.allocator.create(DocumentVersion);
    version.* = try DocumentVersion.init(std.testing.allocator, "v1", "alice");

    try index.addVersion("src/test.zig", version);

    try std.testing.expectEqual(@as(u64, 1), index.total_versions);
}

test "DocumentHistoryIndex.queryByAuthor" {
    var index = DocumentHistoryIndex.init(std.testing.allocator);
    defer index.deinit();

    const version1 = try std.testing.allocator.create(DocumentVersion);
    version1.* = try DocumentVersion.init(std.testing.allocator, "v1", "alice");

    const version2 = try std.testing.allocator.create(DocumentVersion);
    version2.* = try DocumentVersion.init(std.testing.allocator, "v2", "bob");

    try index.addVersion("src/test.zig", version1);
    try index.addVersion("src/main.zig", version2);

    var results = try index.queryByAuthor("alice");

    defer {
        for (results.items) |r| std.testing.allocator.free(r);
        results.deinit(std.testing.allocator);
    }

    try std.testing.expectEqual(@as(usize, 1), results.items.len);
    try std.testing.expectEqualStrings("src/test.zig", results.items[0]);
}

test "DocumentHistoryCartridge.init and addVersion" {
    var cartridge = try DocumentHistoryCartridge.init(std.testing.allocator, 100);
    defer cartridge.deinit();

    const version = try std.testing.allocator.create(DocumentVersion);
    version.* = try DocumentVersion.init(std.testing.allocator, "v1", "alice");

    try cartridge.addVersion("src/test.zig", version);

    try std.testing.expectEqual(@as(u64, 1), cartridge.header.entry_count);
}

test "DocumentHistoryCartridge.queryByAuthor" {
    var cartridge = try DocumentHistoryCartridge.init(std.testing.allocator, 100);
    defer cartridge.deinit();

    const version1 = try std.testing.allocator.create(DocumentVersion);
    version1.* = try DocumentVersion.init(std.testing.allocator, "v1", "alice");

    const version2 = try std.testing.allocator.create(DocumentVersion);
    version2.* = try DocumentVersion.init(std.testing.allocator, "v2", "bob");

    try cartridge.addVersion("src/test.zig", version1);
    try cartridge.addVersion("src/main.zig", version2);

    var results = try cartridge.queryByAuthor("alice");

    defer {
        for (results.items) |r| std.testing.allocator.free(r);
        results.deinit(std.testing.allocator);
    }

    try std.testing.expectEqual(@as(usize, 1), results.items.len);
}

test "DocumentHistoryCartridge.getHistory" {
    var cartridge = try DocumentHistoryCartridge.init(std.testing.allocator, 100);
    defer cartridge.deinit();

    const version = try std.testing.allocator.create(DocumentVersion);
    version.* = try DocumentVersion.init(std.testing.allocator, "v1", "alice");

    try cartridge.addVersion("src/test.zig", version);

    const history = cartridge.getHistory("src/test.zig");

    try std.testing.expect(history != null);
    try std.testing.expectEqual(@as(usize, 1), history.?.versions.items.len);
}
