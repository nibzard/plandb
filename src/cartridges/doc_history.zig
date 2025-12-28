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
        for (self.versions.items) |*version_ptr| {
            version_ptr.*.deinit(self.allocator);
            self.allocator.destroy(version_ptr.*);
        }
        self.versions.deinit(self.allocator);

        // Free branch keys and values
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
        // Remove old entry if exists
        if (self.branches.fetchRemove(version.branch)) |old_kv| {
            self.allocator.free(old_kv.key);
            self.allocator.free(old_kv.value);
        }
        // Add new entry with owned copies
        const key_copy = try self.allocator.dupe(u8, version.branch);
        const value_copy = try self.allocator.dupe(u8, version.version_id);
        try self.branches.put(key_copy, value_copy);
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

// ==================== Change Statistics ====================

/// Change statistics for a document or time range
pub const ChangeStatistics = struct {
    /// Total number of versions
    version_count: u64,
    /// Total lines added
    lines_added: u64,
    /// Total lines removed
    lines_removed: u64,
    /// Net line change
    net_change: i64,
    /// Number of distinct authors
    author_count: u64,
    /// Change frequency (versions per day)
    frequency_per_day: f64,
    /// Impact score (weighted by severity)
    impact_score: f64,

    /// Initialize empty statistics
    pub fn init() ChangeStatistics {
        return ChangeStatistics{
            .version_count = 0,
            .lines_added = 0,
            .lines_removed = 0,
            .net_change = 0,
            .author_count = 0,
            .frequency_per_day = 0.0,
            .impact_score = 0.0,
        };
    }
};

// ==================== Change Impact Analysis ====================

/// Risk level for a change based on historical patterns
pub const ChangeRisk = enum(u8) {
    /// Low risk - unlikely to cause issues
    low = 1,
    /// Medium risk - some potential for issues
    medium = 2,
    /// High risk - high probability of follow-up issues
    high = 3,
    /// Critical risk - very dangerous change
    critical = 4,

    pub fn fromScore(score: f64) ChangeRisk {
        if (score < 0.3) return .low;
        if (score < 0.6) return .medium;
        if (score < 0.8) return .high;
        return .critical;
    }

    pub fn toColor(risk: ChangeRisk) []const u8 {
        return switch (risk) {
            .low => "green",
            .medium => "yellow",
            .high => "orange",
            .critical => "red",
        };
    }
};

/// Change risk analysis result
pub const ChangeRiskAnalysis = struct {
    /// Overall risk level
    risk_level: ChangeRisk,
    /// Risk score (0-1)
    risk_score: f64,
    /// Risk factors contributing to score
    risk_factors: ArrayListManaged(RiskFactor),
    /// Similar historical changes and their outcomes
    historical_comparisons: ArrayListManaged(HistoricalComparison),
    /// Predicted regression probability
    regression_probability: f64,
    /// Recommended actions
    recommendations: ArrayListManaged([]const u8),

    pub const RiskFactor = struct {
        /// Factor name (e.g., "high_change_frequency", "complex_diff")
        name: []const u8,
        /// Impact on overall score (0-1)
        weight: f64,
        /// Description of why this is a risk
        description: []const u8,

        pub fn deinit(self: RiskFactor, allocator: std.mem.Allocator) void {
            allocator.free(self.name);
            allocator.free(self.description);
        }
    };

    pub const HistoricalComparison = struct {
        /// Similar change ID
        change_id: []const u8,
        /// Similarity score (0-1)
        similarity: f64,
        /// Whether that change caused issues
        caused_issues: bool,
        /// Time to issue (seconds, null if no issue)
        time_to_issue: ?u64,

        pub fn deinit(self: HistoricalComparison, allocator: std.mem.Allocator) void {
            allocator.free(self.change_id);
        }
    };

    pub fn init() ChangeRiskAnalysis {
        return ChangeRiskAnalysis{
            .risk_level = .low,
            .risk_score = 0.0,
            .risk_factors = .{},
            .historical_comparisons = .{},
            .regression_probability = 0.0,
            .recommendations = .{},
        };
    }

    pub fn deinit(self: *ChangeRiskAnalysis, allocator: std.mem.Allocator) void {
        for (self.risk_factors.items) |*f| f.deinit(allocator);
        self.risk_factors.deinit(allocator);

        for (self.historical_comparisons.items) |*c| c.deinit(allocator);
        self.historical_comparisons.deinit(allocator);

        for (self.recommendations.items) |r| allocator.free(r);
        self.recommendations.deinit(allocator);
    }

    /// Add a risk factor
    pub fn addRiskFactor(self: *ChangeRiskAnalysis, allocator: std.mem.Allocator, name: []const u8, weight: f64, description: []const u8) !void {
        try self.risk_factors.append(allocator, .{
            .name = try allocator.dupe(u8, name),
            .weight = weight,
            .description = try allocator.dupe(u8, description),
        });
    }

    /// Add a recommendation
    pub fn addRecommendation(self: *ChangeRiskAnalysis, allocator: std.mem.Allocator, recommendation: []const u8) !void {
        try self.recommendations.append(allocator, try allocator.dupe(u8, recommendation));
    }

    /// Update risk level based on score
    pub fn updateRiskLevel(self: *ChangeRiskAnalysis) void {
        self.risk_level = ChangeRisk.fromScore(self.risk_score);
    }
};

/// Hot file metrics - files with high change activity
pub const HotFileMetrics = struct {
    /// File path
    file_path: []const u8,
    /// Total change count
    change_count: u64,
    /// Change frequency (changes per day)
    change_frequency: f64,
    /// Average severity of changes
    avg_severity: f64,
    /// Churn rate (lines changed / total lines)
    churn_rate: f64,
    /// Bug correlation (changes followed by bugs / total changes)
    bug_correlation: f64,
    /// Risk score
    risk_score: f64,

    pub fn deinit(self: HotFileMetrics, allocator: std.mem.Allocator) void {
        allocator.free(self.file_path);
    }
};

/// Change churn statistics
pub const ChangeChurnMetrics = struct {
    /// Total files changed
    total_files: u64,
    /// High churn files (>10% change rate)
    high_churn_count: u64,
    /// Medium churn files (1-10% change rate)
    medium_churn_count: u64,
    /// Low churn files (<1% change rate)
    low_churn_count: u64,
    /// Average churn across all files
    avg_churn_rate: f64,
    /// Churn distribution by directory
    directory_churn: ArrayListManaged(DirectoryChurn),

    pub const DirectoryChurn = struct {
        /// Directory path
        directory: []const u8,
        /// Total change count
        change_count: u64,
        /// Average churn rate
        avg_churn_rate: f64,
        /// Risk score for this directory
        risk_score: f64,

        pub fn deinit(self: DirectoryChurn, allocator: std.mem.Allocator) void {
            allocator.free(self.directory);
        }
    };

    pub fn init(allocator: std.mem.Allocator) ChangeChurnMetrics {
        _ = allocator;
        return ChangeChurnMetrics{
            .total_files = 0,
            .high_churn_count = 0,
            .medium_churn_count = 0,
            .low_churn_count = 0,
            .avg_churn_rate = 0.0,
            .directory_churn = .{},
        };
    }

    pub fn deinit(self: *ChangeChurnMetrics, allocator: std.mem.Allocator) void {
        for (self.directory_churn.items) |*d| d.deinit(allocator);
        self.directory_churn.deinit(allocator);
    }
};

/// Impact prediction for a proposed change
pub const ImpactPrediction = struct {
    /// Predicted risk level
    predicted_risk: ChangeRisk,
    /// Confidence in prediction (0-1)
    confidence: f64,
    /// Predicted regression probability
    regression_probability: f64,
    /// Estimated affected components
    affected_components: ArrayListManaged([]const u8),
    /// Similar historical changes
    similar_changes: ArrayListManaged(ChangeRiskAnalysis.HistoricalComparison),
    /// Testing recommendations
    testing_recommendations: ArrayListManaged([]const u8),

    pub fn init(allocator: std.mem.Allocator) ImpactPrediction {
        _ = allocator;
        return ImpactPrediction{
            .predicted_risk = .low,
            .confidence = 0.0,
            .regression_probability = 0.0,
            .affected_components = .{},
            .similar_changes = .{},
            .testing_recommendations = .{},
        };
    }

    pub fn deinit(self: *ImpactPrediction, allocator: std.mem.Allocator) void {
        for (self.affected_components.items) |c| allocator.free(c);
        self.affected_components.deinit(allocator);

        for (self.similar_changes.items) |*c| c.deinit(allocator);
        self.similar_changes.deinit(allocator);

        for (self.testing_recommendations.items) |r| allocator.free(r);
        self.testing_recommendations.deinit(allocator);
    }
};

// ==================== Query Filters ====================

/// Change log entry for query results
pub const ChangeLogEntry = struct {
    /// Document path
    document_path: []const u8,
    /// Version ID
    version_id: []const u8,
    /// Author
    author: []const u8,
    /// Timestamp
    timestamp: i64,
    /// Change intent
    intent: ChangeIntent,
    /// Change severity
    severity: ChangeSeverity,
    /// Lines added
    lines_added: u32,
    /// Lines removed
    lines_removed: u32,
    /// Linked issues
    linked_issues: []const []const u8,
    /// Commit message
    message: []const u8,

    /// Free entry resources
    pub fn deinit(self: ChangeLogEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.document_path);
        allocator.free(self.version_id);
        allocator.free(self.author);
        for (self.linked_issues) |issue| allocator.free(issue);
        allocator.free(self.linked_issues);
        allocator.free(self.message);
    }
};

/// Filters for changelog queries
pub const ChangeLogFilter = struct {
    /// Filter by author (null = no filter)
    author: ?[]const u8 = null,
    /// Filter by intent (null = no filter)
    intent: ?ChangeIntent = null,
    /// Filter by severity (null = no filter)
    severity: ?ChangeSeverity = null,
    /// Filter by start time (0 = no filter)
    start_time: i64 = 0,
    /// Filter by end time (0 = no filter)
    end_time: i64 = 0,
    /// Filter by linked issue (null = no filter)
    linked_issue: ?[]const u8 = null,
    /// Filter by branch (null = no filter)
    branch: ?[]const u8 = null,

    /// Check if version matches filters
    pub fn matches(self: ChangeLogFilter, version: *const DocumentVersion) bool {
        // Author filter
        if (self.author) |author| {
            if (!std.mem.eql(u8, author, version.author)) return false;
        }

        // Intent filter
        if (self.intent) |intent| {
            if (intent != version.intent) return false;
        }

        // Severity filter
        if (self.severity) |severity| {
            if (severity != version.severity) return false;
        }

        // Time range filter
        if (self.start_time != 0 and version.timestamp < self.start_time) {
            return false;
        }
        if (self.end_time != 0 and version.timestamp > self.end_time) {
            return false;
        }

        // Linked issue filter
        if (self.linked_issue) |issue| {
            var found = false;
            for (version.linked_issues.items) |linked| {
                if (std.mem.eql(u8, issue, linked)) {
                    found = true;
                    break;
                }
            }
            if (!found) return false;
        }

        // Branch filter
        if (self.branch) |branch| {
            if (!std.mem.eql(u8, branch, version.branch)) return false;
        }

        return true;
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
            self.allocator.destroy(entry.value_ptr.*);
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
        // Check if history already exists
        const history = if (self.histories.get(document_path)) |h| h else blk: {
            // Create new history
            const path_copy = try self.allocator.dupe(u8, document_path);
            const h = try self.allocator.create(DocumentHistory);
            h.* = try DocumentHistory.init(self.allocator, document_path);
            try self.histories.put(path_copy, h);
            break :blk h;
        };

        // Add version to history
        try history.addVersion(version);

        // Update author index
        if (self.author_index.getPtr(version.author)) |paths| {
            const path_copy = try self.allocator.dupe(u8, document_path);
            try paths.append(self.allocator, path_copy);
        } else {
            const author_copy = try self.allocator.dupe(u8, version.author);
            var paths = ArrayListManaged([]const u8){};
            const path_copy = try self.allocator.dupe(u8, document_path);
            try paths.append(self.allocator, path_copy);
            try self.author_index.put(author_copy, paths);
        }

        // Update commit index
        if (self.commit_index.getPtr(version.commit_id)) |paths| {
            const path_copy2 = try self.allocator.dupe(u8, document_path);
            try paths.append(self.allocator, path_copy2);
        } else {
            const commit_copy = try self.allocator.dupe(u8, version.commit_id);
            var paths = ArrayListManaged([]const u8){};
            const path_copy2 = try self.allocator.dupe(u8, document_path);
            try paths.append(self.allocator, path_copy2);
            try self.commit_index.put(commit_copy, paths);
        }

        // Update intent index
        const intent_str = @tagName(version.intent);
        if (self.intent_index.getPtr(intent_str)) |versions| {
            try versions.append(self.allocator, version);
        } else {
            const intent_copy = try self.allocator.dupe(u8, intent_str);
            var versions = ArrayListManaged(*DocumentVersion){};
            try versions.append(self.allocator, version);
            try self.intent_index.put(intent_copy, versions);
        }

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

    /// Query changelog with filters
    pub fn queryChangelog(self: *const DocumentHistoryIndex, document_path: ?[]const u8, filter: ChangeLogFilter) !ArrayListManaged(ChangeLogEntry) {
        var results = ArrayListManaged(ChangeLogEntry){};

        // If document_path specified, only query that document
        if (document_path) |path| {
            const history = self.histories.get(path) orelse return results;
            try self.queryHistoryChangelog(history, path, filter, &results);
        } else {
            // Query all documents
            var it = self.histories.iterator();
            while (it.next()) |entry| {
                try self.queryHistoryChangelog(entry.value_ptr.*, entry.key_ptr.*, filter, &results);
            }
        }

        // Sort by timestamp (most recent first)
        std.sort.insertion(ChangeLogEntry, results.items, {}, struct {
            fn compare(_: void, a: ChangeLogEntry, b: ChangeLogEntry) bool {
                return a.timestamp > b.timestamp;
            }
        }.compare);

        return results;
    }

    /// Helper to query changelog for a single history
    fn queryHistoryChangelog(self: *const DocumentHistoryIndex, history: *const DocumentHistory, path: []const u8, filter: ChangeLogFilter, results: *ArrayListManaged(ChangeLogEntry)) !void {
        for (history.versions.items) |version| {
            if (!filter.matches(version)) continue;

            // Calculate lines added/removed
            var lines_added: u32 = 0;
            var lines_removed: u32 = 0;
            for (version.diffs.items) |diff| {
                lines_added += diff.lines_added;
                lines_removed += diff.lines_removed;
            }

            // Duplicate linked issues
            var issues = try self.allocator.alloc([]const u8, version.linked_issues.items.len);
            for (version.linked_issues.items, 0..) |issue, i| {
                issues[i] = try self.allocator.dupe(u8, issue);
            }

            const entry = ChangeLogEntry{
                .document_path = try self.allocator.dupe(u8, path),
                .version_id = try self.allocator.dupe(u8, version.version_id),
                .author = try self.allocator.dupe(u8, version.author),
                .timestamp = version.timestamp,
                .intent = version.intent,
                .severity = version.severity,
                .lines_added = lines_added,
                .lines_removed = lines_removed,
                .linked_issues = issues,
                .message = try self.allocator.dupe(u8, version.message),
            };

            try results.append(self.allocator, entry);
        }
    }

    /// Compute change statistics for a document or time range
    pub fn computeStatistics(self: *const DocumentHistoryIndex, document_path: ?[]const u8, filter: ChangeLogFilter) !ChangeStatistics {
        var stats = ChangeStatistics.init();
        var authors = std.StringHashMap(void).init(self.allocator);
        defer authors.deinit();

        var earliest_time: i64 = std.math.maxInt(i64);
        var latest_time: i64 = 0;

        // Process documents
        if (document_path) |path| {
            const history = self.histories.get(path) orelse return stats;
            try self.computeHistoryStats(history, filter, &stats, &authors, &earliest_time, &latest_time);
        } else {
            var it = self.histories.iterator();
            while (it.next()) |entry| {
                try self.computeHistoryStats(entry.value_ptr.*, filter, &stats, &authors, &earliest_time, &latest_time);
            }
        }

        // Compute derived metrics
        stats.author_count = authors.count();
        if (stats.version_count > 0 and earliest_time < latest_time) {
            const days = @as(f64, @floatFromInt(latest_time - earliest_time)) / (24.0 * 3600.0);
            if (days > 0) {
                stats.frequency_per_day = @as(f64, @floatFromInt(stats.version_count)) / days;
            }
        }

        return stats;
    }

    /// Helper to compute statistics for a single history
    fn computeHistoryStats(self: *const DocumentHistoryIndex, history: *const DocumentHistory, filter: ChangeLogFilter, stats: *ChangeStatistics, authors: *std.StringHashMap(void), earliest_time: *i64, latest_time: *i64) !void {
        _ = self;
        for (history.versions.items) |version| {
            if (!filter.matches(version)) continue;

            stats.version_count += 1;

            // Track authors
            try authors.put(version.author, {});

            // Track time range
            if (version.timestamp < earliest_time.*) {
                earliest_time.* = version.timestamp;
            }
            if (version.timestamp > latest_time.*) {
                latest_time.* = version.timestamp;
            }

            // Sum line changes
            for (version.diffs.items) |diff| {
                stats.lines_added += diff.lines_added;
                stats.lines_removed += diff.lines_removed;
            }

            // Compute impact score (weighted by severity)
            const severity_weight: f64 = switch (version.severity) {
                .trivial => 0.1,
                .minor => 0.25,
                .moderate => 0.5,
                .major => 1.0,
                .critical => 2.0,
            };
            stats.impact_score += severity_weight;
        }
        stats.net_change = @bitCast(@as(i64, @intCast(stats.lines_added)) - @as(i64, @intCast(stats.lines_removed)));
    }

    /// Blame query: who last touched line N?
    pub fn queryBlame(self: *const DocumentHistoryIndex, document_path: []const u8, line_number: u32) !?ChangeLogEntry {
        const history = self.histories.get(document_path) orelse return null;

        // Search versions in reverse order (most recent first)
        var i: usize = history.versions.items.len;
        while (i > 0) {
            i -= 1;
            const version = history.versions.items[i];

            // Check if any diff covers this line
            for (version.diffs.items) |diff| {
                const line_end = diff.start_line + diff.lines_added;
                if (line_number >= diff.start_line and line_number < line_end) {
                    // Found it - create entry
                    var lines_added: u32 = 0;
                    var lines_removed: u32 = 0;
                    for (version.diffs.items) |d| {
                        lines_added += d.lines_added;
                        lines_removed += d.lines_removed;
                    }

                    var issues = try self.allocator.alloc([]const u8, version.linked_issues.items.len);
                    for (version.linked_issues.items, 0..) |issue, j| {
                        issues[j] = try self.allocator.dupe(u8, issue);
                    }

                    return ChangeLogEntry{
                        .document_path = try self.allocator.dupe(u8, document_path),
                        .version_id = try self.allocator.dupe(u8, version.version_id),
                        .author = try self.allocator.dupe(u8, version.author),
                        .timestamp = version.timestamp,
                        .intent = version.intent,
                        .severity = version.severity,
                        .lines_added = lines_added,
                        .lines_removed = lines_removed,
                        .linked_issues = issues,
                        .message = try self.allocator.dupe(u8, version.message),
                    };
                }
            }
        }

        return null;
    }

    /// Query by severity level
    pub fn queryBySeverity(self: *const DocumentHistoryIndex, severity: ChangeSeverity) !ArrayListManaged(*DocumentVersion) {
        var results = ArrayListManaged(*DocumentVersion){};

        var it = self.histories.iterator();
        while (it.next()) |entry| {
            const history = entry.value_ptr.*;
            for (history.versions.items) |version| {
                if (version.severity == severity) {
                    try results.append(self.allocator, version);
                }
            }
        }

        return results;
    }

    /// Query by time range
    pub fn queryByTimeRange(self: *const DocumentHistoryIndex, start_time: i64, end_time: i64) !ArrayListManaged(*DocumentVersion) {
        var results = ArrayListManaged(*DocumentVersion){};

        var it = self.histories.iterator();
        while (it.next()) |entry| {
            const history = entry.value_ptr.*;
            for (history.versions.items) |version| {
                if (version.timestamp >= start_time and version.timestamp <= end_time) {
                    try results.append(self.allocator, version);
                }
            }
        }

        return results;
    }

    // ==================== Change Impact Analysis ====================

    /// Analyze change risk for a specific document version
    pub fn analyzeChangeRisk(self: *const DocumentHistoryIndex, document_path: []const u8, version_id: []const u8) !ChangeRiskAnalysis {
        const history = self.histories.get(document_path) orelse {
            return ChangeRiskAnalysis.init();
        };

        var analysis = ChangeRiskAnalysis.init();
        errdefer analysis.deinit(self.allocator);

        // Find the target version
        const target_version = blk: {
            for (history.versions.items) |*v| {
                if (std.mem.eql(u8, v.*.version_id, version_id)) {
                    break :blk v.*;
                }
            }
            return analysis;
        };

        var total_score: f64 = 0.0;
        var factor_count: usize = 0;

        // Factor 1: Change severity impact
        const severity_weight: f64 = switch (target_version.severity) {
            .trivial => 0.1,
            .minor => 0.25,
            .moderate => 0.5,
            .major => 0.75,
            .critical => 1.0,
        };
        try analysis.addRiskFactor(
            self.allocator,
            "severity",
            severity_weight * 0.3,
            "Higher severity changes have greater impact"
        );
        total_score += severity_weight * 0.3;
        factor_count += 1;

        // Factor 2: Change frequency (is this file changing often?)
        const file_changes = history.versions.items.len;
        const freq_factor = @min(1.0, @as(f64, @floatFromInt(file_changes)) / 100.0);
        if (freq_factor > 0.1) {
            try analysis.addRiskFactor(
                self.allocator,
                "high_change_frequency",
                freq_factor * 0.2,
                "File changes frequently, higher regression risk"
            );
            total_score += freq_factor * 0.2;
            factor_count += 1;
        }

        // Factor 3: Lines changed impact
        var lines_changed: u64 = 0;
        for (target_version.diffs.items) |d| {
            lines_changed += d.lines_added + d.lines_removed;
        }
        const size_factor = @min(1.0, @as(f64, @floatFromInt(lines_changed)) / 1000.0);
        if (size_factor > 0.3) {
            try analysis.addRiskFactor(
                self.allocator,
                "large_change",
                size_factor * 0.25,
                "Large changes have higher risk"
            );
            total_score += size_factor * 0.25;
            factor_count += 1;
        }

        // Factor 4: Intent-based risk
        const intent_factor: f64 = switch (target_version.intent) {
            .docs, .style => 0.1,
            .tests => 0.2,
            .refactor => 0.5,
            .feature => 0.4,
            .perf => 0.6,
            .bugfix => 0.7,
            .security => 0.9,
            .other => 0.3,
        };
        if (intent_factor > 0.5) {
            try analysis.addRiskFactor(
                self.allocator,
                "high_risk_intent",
                intent_factor * 0.15,
                "This change type has historical correlation with issues"
            );
            total_score += intent_factor * 0.15;
            factor_count += 1;
        }

        // Factor 5: Recent changes (rapid succession)
        var recent_changes: usize = 0;
        const one_hour_ago = target_version.timestamp - 3600;
        for (history.versions.items) |v| {
            if (v.timestamp >= one_hour_ago and v.timestamp != target_version.timestamp) {
                recent_changes += 1;
            }
        }
        if (recent_changes > 3) {
            const rapid_factor = @min(1.0, @as(f64, @floatFromInt(recent_changes)) / 10.0);
            try analysis.addRiskFactor(
                self.allocator,
                "rapid_changes",
                rapid_factor * 0.1,
                "Multiple recent changes increase regression risk"
            );
            total_score += rapid_factor * 0.1;
            factor_count += 1;
        }

        // Calculate final score (normalized by factor count)
        analysis.risk_score = if (factor_count > 0)
            @min(1.0, total_score)
        else
            0.1; // Low default risk

        analysis.updateRiskLevel();

        // Generate recommendations based on risk
        if (analysis.risk_level == .high or analysis.risk_level == .critical) {
            try analysis.addRecommendation(self.allocator, "Increase test coverage for affected files");
            try analysis.addRecommendation(self.allocator, "Consider code review by senior developer");
            try analysis.addRecommendation(self.allocator, "Plan for rollback capability");
        }
        if (analysis.risk_level == .critical) {
            try analysis.addRecommendation(self.allocator, "Staged rollout recommended");
            try analysis.addRecommendation(self.allocator, "Monitor closely for 72 hours post-deployment");
        }

        // Estimate regression probability
        analysis.regression_probability = analysis.risk_score * 0.7; // 70% correlation

        return analysis;
    }

    /// Get hot files - files with high change activity
    pub fn getHotFiles(self: *const DocumentHistoryIndex, limit: usize) !ArrayListManaged(HotFileMetrics) {
        var files = try self.allocator.alloc(HotFileMetrics, @min(limit, self.histories.count()));
        defer self.allocator.free(files);

        var idx: usize = 0;
        var it = self.histories.iterator();
        while (it.next()) |entry| : (idx += 1) {
            if (idx >= files.len) break;

            const path = entry.key_ptr.*;
            const history = entry.value_ptr.*;

            const stats = try self.computeStatistics(path, .{});
            _ = stats.version_count; // Use the value

            // Calculate change frequency
            const earliest: i64 = if (history.versions.items.len > 0)
                history.versions.items[history.versions.items.len - 1].timestamp
            else
                std.time.timestamp();
            const latest: i64 = if (history.versions.items.len > 0)
                history.versions.items[0].timestamp
            else
                std.time.timestamp();
            const days = @max(1, @divTrunc(latest - earliest, 86400));

            // Calculate average severity
            var total_severity: f64 = 0;
            for (history.versions.items) |v| {
                total_severity += switch (v.severity) {
                    .trivial => 1, .minor => 2, .moderate => 3, .major => 4, .critical => 5,
                };
            }
            const avg_severity = if (history.versions.items.len > 0)
                total_severity / @as(f64, @floatFromInt(history.versions.items.len))
            else
                0;

            // Estimate churn rate (rough approximation)
            var total_lines: u64 = 0;
            for (history.versions.items) |v| {
                for (v.diffs.items) |d| {
                    total_lines += d.lines_added + d.lines_removed;
                }
            }
            const churn_rate = if (stats.version_count > 0)
                @as(f64, @floatFromInt(total_lines)) / @as(f64, @floatFromInt(stats.version_count)) / 1000.0
            else
                0;

            files[idx] = .{
                .file_path = try self.allocator.dupe(u8, path),
                .change_count = stats.version_count,
                .change_frequency = @as(f64, @floatFromInt(stats.version_count)) / @as(f64, @floatFromInt(days)),
                .avg_severity = avg_severity / 5.0, // Normalize to 0-1
                .churn_rate = @min(1.0, churn_rate),
                .bug_correlation = 0.0, // Would need bug tracking integration
                .risk_score = 0.0, // Calculated below
            };

            // Calculate risk score
            const freq_score = @min(1.0, files[idx].change_frequency / 10.0);
            const severity_score = files[idx].avg_severity;
            const churn_score = @min(1.0, files[idx].churn_rate * 10.0);
            files[idx].risk_score = (freq_score * 0.4) + (severity_score * 0.4) + (churn_score * 0.2);
        }

        // Sort by risk score (descending)
        std.sort.insertion(HotFileMetrics, files[0..idx], {}, struct {
            fn lessThan(_: void, a: HotFileMetrics, b: HotFileMetrics) bool {
                return a.risk_score > b.risk_score;
            }
        }.lessThan);

        var result = ArrayListManaged(HotFileMetrics){};
        for (files[0..idx]) |f| {
            try result.append(self.allocator, f);
        }

        return result;
    }

    /// Calculate change churn metrics
    pub fn calculateChurnMetrics(self: *const DocumentHistoryIndex) !ChangeChurnMetrics {
        var metrics = ChangeChurnMetrics.init(self.allocator);
        errdefer metrics.deinit(self.allocator);

        var directory_changes = std.StringHashMap(struct {
            count: u64,
            total_churn: f64,
            files: usize,
        }).init(self.allocator);
        defer {
            var dir_it = directory_changes.iterator();
            while (dir_it.next()) |e| {
                self.allocator.free(e.key_ptr.*);
            }
            directory_changes.deinit();
        }

        var file_it = self.histories.iterator();
        while (file_it.next()) |entry| {
            const path = entry.key_ptr.*;
            const history = entry.value_ptr.*;

            metrics.total_files += 1;

            // Calculate file churn
            var total_lines: u64 = 0;
            for (history.versions.items) |v| {
                for (v.diffs.items) |d| {
                    total_lines += d.lines_added + d.lines_removed;
                }
            }

            const avg_churn = if (history.versions.items.len > 0)
                @as(f64, @floatFromInt(total_lines)) / @as(f64, @floatFromInt(history.versions.items.len)) / 1000.0
            else
                0;

            // Categorize churn
            if (avg_churn > 0.1) {
                metrics.high_churn_count += 1;
            } else if (avg_churn > 0.01) {
                metrics.medium_churn_count += 1;
            } else {
                metrics.low_churn_count += 1;
            }

            // Track directory-level churn
            const dir = blk: {
                if (std.mem.lastIndexOfScalar(u8, path, '/')) |idx| {
                    break :blk path[0..idx];
                }
                break :blk ".";
            };

            const dir_entry = try directory_changes.getOrPut(dir);
            if (!dir_entry.found_existing) {
                dir_entry.key_ptr.* = try self.allocator.dupe(u8, dir);
                dir_entry.value_ptr.* = .{ .count = 0, .total_churn = 0.0, .files = 0 };
            }
            dir_entry.value_ptr.count += history.versions.items.len;
            dir_entry.value_ptr.total_churn += avg_churn;
            dir_entry.value_ptr.files += 1;
        }

        // Calculate directory metrics
        var dir_it = directory_changes.iterator();
        while (dir_it.next()) |e| {
            const dir_churn = e.value_ptr.total_churn / @as(f64, @floatFromInt(e.value_ptr.files));
            const risk_score = @min(1.0, dir_churn * 10.0);

            try metrics.directory_churn.append(self.allocator, .{
                .directory = try self.allocator.dupe(u8, e.key_ptr.*),
                .change_count = e.value_ptr.count,
                .avg_churn_rate = dir_churn,
                .risk_score = risk_score,
            });
        }

        // Calculate overall average churn
        const total_churn = metrics.high_churn_count + metrics.medium_churn_count + metrics.low_churn_count;
        metrics.avg_churn_rate = if (total_churn > 0)
            @as(f64, @floatFromInt(metrics.high_churn_count)) * 0.5 +
            @as(f64, @floatFromInt(metrics.medium_churn_count)) * 0.1
        else
            0;

        return metrics;
    }

    /// Predict impact for a proposed change
    pub fn predictImpact(
        self: *const DocumentHistoryIndex,
        document_path: []const u8,
        proposed_severity: ChangeSeverity,
        proposed_intent: ChangeIntent,
        estimated_lines_changed: u64
    ) !ImpactPrediction {
        var prediction = ImpactPrediction.init(self.allocator);
        errdefer prediction.deinit(self.allocator);

        // Get historical data for this file
        const history = self.histories.get(document_path);

        var risk_score: f64 = 0.0;
        var confidence: f64 = 0.5;

        // Base risk from severity
        risk_score += switch (proposed_severity) {
            .trivial => 0.1,
            .minor => 0.25,
            .moderate => 0.5,
            .major => 0.75,
            .critical => 1.0,
        };

        // Risk from intent
        risk_score += switch (proposed_intent) {
            .docs, .style => 0.05,
            .tests => 0.1,
            .refactor => 0.2,
            .feature => 0.15,
            .perf => 0.25,
            .bugfix => 0.3,
            .security => 0.4,
            .other => 0.1,
        };

        // Factor in file history
        if (history) |h| {
            confidence = @min(1.0, @as(f64, @floatFromInt(h.versions.items.len)) / 50.0);

            // Check for similar past changes
            var similar_count: usize = 0;
            var issue_count: usize = 0;

            for (h.versions.items) |v| {
                const severity_match = v.severity == proposed_severity;
                const intent_match = v.intent == proposed_intent;
                if (severity_match and intent_match) {
                    similar_count += 1;
                    // Would check bug tracking here
                    // For now, estimate based on severity/intent
                    if (proposed_intent == .security or proposed_severity == .critical) {
                        issue_count += 1;
                    }
                }
            }

            if (similar_count > 0) {
                prediction.regression_probability = @as(f64, @floatFromInt(issue_count)) / @as(f64, @floatFromInt(similar_count));
            }

            // Add affected components (would analyze dependencies in real system)
            try prediction.affected_components.append(self.allocator, try self.allocator.dupe(u8, document_path));
        }

        // Normalize risk score
        risk_score = @min(1.0, risk_score / 2.0);
        prediction.predicted_risk = ChangeRisk.fromScore(risk_score);
        prediction.confidence = confidence;

        // Generate testing recommendations
        if (prediction.predicted_risk == .high or prediction.predicted_risk == .critical) {
            try prediction.testing_recommendations.append(self.allocator, try self.allocator.dupe(u8, "Unit tests for all modified functions"));
            try prediction.testing_recommendations.append(self.allocator, try self.allocator.dupe(u8, "Integration tests for affected components"));
            try prediction.testing_recommendations.append(self.allocator, try self.allocator.dupe(u8, "Performance baseline comparison"));
        }
        if (proposed_intent == .security or proposed_intent == .bugfix) {
            try prediction.testing_recommendations.append(self.allocator, try self.allocator.dupe(u8, "Regression tests for fixed vulnerability/bug"));
        }
        if (estimated_lines_changed > 500) {
            try prediction.testing_recommendations.append(self.allocator, try self.allocator.dupe(u8, "Comprehensive end-to-end testing"));
        }

        return prediction;
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

    /// Query changelog with filters
    pub fn queryChangelog(self: *const DocumentHistoryCartridge, document_path: ?[]const u8, filter: ChangeLogFilter) !ArrayListManaged(ChangeLogEntry) {
        return self.index.queryChangelog(document_path, filter);
    }

    /// Compute change statistics
    pub fn computeStatistics(self: *const DocumentHistoryCartridge, document_path: ?[]const u8, filter: ChangeLogFilter) !ChangeStatistics {
        return self.index.computeStatistics(document_path, filter);
    }

    /// Blame query: who last touched line N?
    pub fn queryBlame(self: *const DocumentHistoryCartridge, document_path: []const u8, line_number: u32) !?ChangeLogEntry {
        return self.index.queryBlame(document_path, line_number);
    }

    /// Query by severity level
    pub fn queryBySeverity(self: *const DocumentHistoryCartridge, severity: ChangeSeverity) !ArrayListManaged(*DocumentVersion) {
        return self.index.queryBySeverity(severity);
    }

    /// Query by time range
    pub fn queryByTimeRange(self: *const DocumentHistoryCartridge, start_time: i64, end_time: i64) !ArrayListManaged(*DocumentVersion) {
        return self.index.queryByTimeRange(start_time, end_time);
    }

    // ==================== Change Impact Analysis ====================

    /// Analyze change risk for a document version
    pub fn analyzeChangeRisk(self: *const DocumentHistoryCartridge, document_path: []const u8, version_id: []const u8) !ChangeRiskAnalysis {
        return self.index.analyzeChangeRisk(document_path, version_id);
    }

    /// Get hot files - files with high change activity
    pub fn getHotFiles(self: *const DocumentHistoryCartridge, limit: usize) !ArrayListManaged(HotFileMetrics) {
        return self.index.getHotFiles(limit);
    }

    /// Calculate change churn metrics
    pub fn calculateChurnMetrics(self: *const DocumentHistoryCartridge) !ChangeChurnMetrics {
        return self.index.calculateChurnMetrics();
    }

    /// Predict impact for a proposed change
    pub fn predictImpact(
        self: *const DocumentHistoryCartridge,
        document_path: []const u8,
        proposed_severity: ChangeSeverity,
        proposed_intent: ChangeIntent,
        estimated_lines_changed: u64
    ) !ImpactPrediction {
        return self.index.predictImpact(document_path, proposed_severity, proposed_intent, estimated_lines_changed);
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

test "ChangeLogFilter.matches - author filter" {
    var version = try DocumentVersion.init(std.testing.allocator, "v1", "alice");
    defer version.deinit(std.testing.allocator);

    const filter = ChangeLogFilter{ .author = "alice" };
    try std.testing.expect(filter.matches(&version));

    const filter2 = ChangeLogFilter{ .author = "bob" };
    try std.testing.expect(!filter2.matches(&version));
}

test "ChangeLogFilter.matches - intent filter" {
    var version = try DocumentVersion.init(std.testing.allocator, "v1", "alice");
    defer version.deinit(std.testing.allocator);
    version.intent = .bugfix;

    const filter = ChangeLogFilter{ .intent = .bugfix };
    try std.testing.expect(filter.matches(&version));

    const filter2 = ChangeLogFilter{ .intent = .feature };
    try std.testing.expect(!filter2.matches(&version));
}

test "ChangeLogFilter.matches - severity filter" {
    var version = try DocumentVersion.init(std.testing.allocator, "v1", "alice");
    defer version.deinit(std.testing.allocator);
    version.severity = .critical;

    const filter = ChangeLogFilter{ .severity = .critical };
    try std.testing.expect(filter.matches(&version));

    const filter2 = ChangeLogFilter{ .severity = .trivial };
    try std.testing.expect(!filter2.matches(&version));
}

test "ChangeLogFilter.matches - time range filter" {
    var version = try DocumentVersion.init(std.testing.allocator, "v1", "alice");
    defer version.deinit(std.testing.allocator);
    version.timestamp = 1000;

    const filter = ChangeLogFilter{ .start_time = 500, .end_time = 1500 };
    try std.testing.expect(filter.matches(&version));

    const filter2 = ChangeLogFilter{ .start_time = 1500, .end_time = 2000 };
    try std.testing.expect(!filter2.matches(&version));
}

test "ChangeLogFilter.matches - linked issue filter" {
    var version = try DocumentVersion.init(std.testing.allocator, "v1", "alice");
    defer version.deinit(std.testing.allocator);
    try version.addLinkedIssue(std.testing.allocator, "ISSUE-123");

    const filter = ChangeLogFilter{ .linked_issue = "ISSUE-123" };
    try std.testing.expect(filter.matches(&version));

    const filter2 = ChangeLogFilter{ .linked_issue = "ISSUE-456" };
    try std.testing.expect(!filter2.matches(&version));
}

test "ChangeLogFilter.matches - combined filters" {
    var version = try DocumentVersion.init(std.testing.allocator, "v1", "alice");
    defer version.deinit(std.testing.allocator);
    version.intent = .bugfix;
    version.severity = .major;
    version.timestamp = 1000;

    const filter = ChangeLogFilter{
        .author = "alice",
        .intent = .bugfix,
        .severity = .major,
        .start_time = 500,
        .end_time = 1500,
    };
    try std.testing.expect(filter.matches(&version));

    // Filter should fail if author doesn't match
    const filter2 = ChangeLogFilter{
        .author = "bob",
        .intent = .bugfix,
    };
    try std.testing.expect(!filter2.matches(&version));
}

test "DocumentHistoryIndex.queryChangelog - single document" {
    var index = DocumentHistoryIndex.init(std.testing.allocator);
    defer index.deinit();

    const version1 = try std.testing.allocator.create(DocumentVersion);
    version1.* = try DocumentVersion.init(std.testing.allocator, "v1", "alice");
    version1.intent = .bugfix;
    version1.timestamp = 1000;
    try version1.addDiff(std.testing.allocator, DiffOp{
        .start_line = 0,
        .lines_removed = 1,
        .lines_added = 2,
        .removed = "old",
        .added = "new1\nnew2",
    });

    const version2 = try std.testing.allocator.create(DocumentVersion);
    version2.* = try DocumentVersion.init(std.testing.allocator, "v2", "bob");
    version2.intent = .feature;
    version2.timestamp = 2000;
    try version2.addDiff(std.testing.allocator, DiffOp{
        .start_line = 5,
        .lines_removed = 0,
        .lines_added = 1,
        .removed = "",
        .added = "new line",
    });

    try index.addVersion("src/test.zig", version1);
    try index.addVersion("src/test.zig", version2);

    // Query all changelog for document
    var results = try index.queryChangelog("src/test.zig", .{});

    defer {
        for (results.items) |r| r.deinit(std.testing.allocator);
        results.deinit(std.testing.allocator);
    }

    try std.testing.expectEqual(@as(usize, 2), results.items.len);
    // Should be sorted by timestamp descending
    try std.testing.expectEqual(@as(i64, 2000), results.items[0].timestamp);
    try std.testing.expectEqualStrings("bob", results.items[0].author);
    try std.testing.expectEqual(@as(i64, 1000), results.items[1].timestamp);
    try std.testing.expectEqualStrings("alice", results.items[1].author);
}

test "DocumentHistoryIndex.queryChangelog - with intent filter" {
    var index = DocumentHistoryIndex.init(std.testing.allocator);
    defer index.deinit();

    const version1 = try std.testing.allocator.create(DocumentVersion);
    version1.* = try DocumentVersion.init(std.testing.allocator, "v1", "alice");
    version1.intent = .bugfix;

    const version2 = try std.testing.allocator.create(DocumentVersion);
    version2.* = try DocumentVersion.init(std.testing.allocator, "v2", "bob");
    version2.intent = .feature;

    try index.addVersion("src/test.zig", version1);
    try index.addVersion("src/test.zig", version2);

    var results = try index.queryChangelog("src/test.zig", .{ .intent = .bugfix });

    defer {
        for (results.items) |r| r.deinit(std.testing.allocator);
        results.deinit(std.testing.allocator);
    }

    try std.testing.expectEqual(@as(usize, 1), results.items.len);
    try std.testing.expectEqual(ChangeIntent.bugfix, results.items[0].intent);
}

test "DocumentHistoryIndex.queryChangelog - all documents" {
    var index = DocumentHistoryIndex.init(std.testing.allocator);
    defer index.deinit();

    const version1 = try std.testing.allocator.create(DocumentVersion);
    version1.* = try DocumentVersion.init(std.testing.allocator, "v1", "alice");

    const version2 = try std.testing.allocator.create(DocumentVersion);
    version2.* = try DocumentVersion.init(std.testing.allocator, "v2", "bob");

    try index.addVersion("src/test.zig", version1);
    try index.addVersion("src/main.zig", version2);

    var results = try index.queryChangelog(null, .{});

    defer {
        for (results.items) |r| r.deinit(std.testing.allocator);
        results.deinit(std.testing.allocator);
    }

    try std.testing.expectEqual(@as(usize, 2), results.items.len);
}

test "DocumentHistoryIndex.computeStatistics" {
    var index = DocumentHistoryIndex.init(std.testing.allocator);
    defer index.deinit();

    var version1 = try std.testing.allocator.create(DocumentVersion);
    version1.* = try DocumentVersion.init(std.testing.allocator, "v1", "alice");
    version1.timestamp = 1000;
    version1.severity = .major;
    try version1.addDiff(std.testing.allocator, DiffOp{
        .start_line = 0,
        .lines_removed = 5,
        .lines_added = 10,
        .removed = "old",
        .added = "new",
    });

    var version2 = try std.testing.allocator.create(DocumentVersion);
    version2.* = try DocumentVersion.init(std.testing.allocator, "v2", "bob");
    version2.timestamp = 2000;
    version2.severity = .minor;
    try version2.addDiff(std.testing.allocator, DiffOp{
        .start_line = 10,
        .lines_removed = 2,
        .lines_added = 3,
        .removed = "old2",
        .added = "new2",
    });

    try index.addVersion("src/test.zig", version1);
    try index.addVersion("src/test.zig", version2);

    const stats = try index.computeStatistics("src/test.zig", .{});

    try std.testing.expectEqual(@as(u64, 2), stats.version_count);
    try std.testing.expectEqual(@as(u64, 13), stats.lines_added);
    try std.testing.expectEqual(@as(u64, 7), stats.lines_removed);
    try std.testing.expectEqual(@as(i64, 6), stats.net_change);
    try std.testing.expectEqual(@as(u64, 2), stats.author_count);
    try std.testing.expectEqual(@as(f64, 1.25), stats.impact_score); // major (1.0) + minor (0.25)
}

test "DocumentHistoryIndex.queryBlame" {
    var index = DocumentHistoryIndex.init(std.testing.allocator);
    defer index.deinit();

    var version1 = try std.testing.allocator.create(DocumentVersion);
    version1.* = try DocumentVersion.init(std.testing.allocator, "v1", "alice");
    version1.timestamp = 1000;
    try version1.addDiff(std.testing.allocator, DiffOp{
        .start_line = 10,
        .lines_removed = 0,
        .lines_added = 5,
        .removed = "",
        .added = "line1\nline2\nline3\nline4\nline5",
    });

    var version2 = try std.testing.allocator.create(DocumentVersion);
    version2.* = try DocumentVersion.init(std.testing.allocator, "v2", "bob");
    version2.timestamp = 2000;
    try version2.addDiff(std.testing.allocator, DiffOp{
        .start_line = 12,
        .lines_removed = 0,
        .lines_added = 2,
        .removed = "",
        .added = "modified1\nmodified2",
    });

    try index.addVersion("src/test.zig", version1);
    try index.addVersion("src/test.zig", version2);

    // Line 12 was modified by bob (most recent)
    const result = try index.queryBlame("src/test.zig", 12);

    try std.testing.expect(result != null);
    defer if (result) |r| r.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("bob", result.?.author);
    try std.testing.expectEqual(@as(i64, 2000), result.?.timestamp);

    // Line 11 was added by alice (never modified)
    const result2 = try index.queryBlame("src/test.zig", 11);

    try std.testing.expect(result2 != null);
    defer if (result2) |r| r.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("alice", result2.?.author);
}

test "DocumentHistoryIndex.queryBySeverity" {
    var index = DocumentHistoryIndex.init(std.testing.allocator);
    defer index.deinit();

    var version1 = try std.testing.allocator.create(DocumentVersion);
    version1.* = try DocumentVersion.init(std.testing.allocator, "v1", "alice");
    version1.severity = .critical;

    var version2 = try std.testing.allocator.create(DocumentVersion);
    version2.* = try DocumentVersion.init(std.testing.allocator, "v2", "bob");
    version2.severity = .trivial;

    try index.addVersion("src/test.zig", version1);
    try index.addVersion("src/main.zig", version2);

    var results = try index.queryBySeverity(.critical);

    defer {
        for (results.items) |r| {
            _ = r;
            // versions owned by index, don't free
        }
        results.deinit(std.testing.allocator);
    }

    try std.testing.expectEqual(@as(usize, 1), results.items.len);
    try std.testing.expectEqual(ChangeSeverity.critical, results.items[0].severity);
}

test "DocumentHistoryIndex.queryByTimeRange" {
    var index = DocumentHistoryIndex.init(std.testing.allocator);
    defer index.deinit();

    var version1 = try std.testing.allocator.create(DocumentVersion);
    version1.* = try DocumentVersion.init(std.testing.allocator, "v1", "alice");
    version1.timestamp = 1000;

    var version2 = try std.testing.allocator.create(DocumentVersion);
    version2.* = try DocumentVersion.init(std.testing.allocator, "v2", "bob");
    version2.timestamp = 2000;

    var version3 = try std.testing.allocator.create(DocumentVersion);
    version3.* = try DocumentVersion.init(std.testing.allocator, "v3", "charlie");
    version3.timestamp = 3000;

    try index.addVersion("src/test.zig", version1);
    try index.addVersion("src/main.zig", version2);
    try index.addVersion("src/lib.zig", version3);

    var results = try index.queryByTimeRange(500, 2500);

    defer {
        for (results.items) |r| {
            _ = r;
            // versions owned by index, don't free
        }
        results.deinit(std.testing.allocator);
    }

    try std.testing.expectEqual(@as(usize, 2), results.items.len);
}

test "DocumentHistoryCartridge.queryChangelog" {
    var cartridge = try DocumentHistoryCartridge.init(std.testing.allocator, 100);
    defer cartridge.deinit();

    var version1 = try std.testing.allocator.create(DocumentVersion);
    version1.* = try DocumentVersion.init(std.testing.allocator, "v1", "alice");
    version1.intent = .bugfix;

    var version2 = try std.testing.allocator.create(DocumentVersion);
    version2.* = try DocumentVersion.init(std.testing.allocator, "v2", "bob");
    version2.intent = .feature;

    try cartridge.addVersion("src/test.zig", version1);
    try cartridge.addVersion("src/test.zig", version2);

    var results = try cartridge.queryChangelog("src/test.zig", .{ .intent = .bugfix });

    defer {
        for (results.items) |r| r.deinit(std.testing.allocator);
        results.deinit(std.testing.allocator);
    }

    try std.testing.expectEqual(@as(usize, 1), results.items.len);
    try std.testing.expectEqual(ChangeIntent.bugfix, results.items[0].intent);
}

test "DocumentHistoryCartridge.computeStatistics" {
    var cartridge = try DocumentHistoryCartridge.init(std.testing.allocator, 100);
    defer cartridge.deinit();

    var version1 = try std.testing.allocator.create(DocumentVersion);
    version1.* = try DocumentVersion.init(std.testing.allocator, "v1", "alice");
    version1.severity = .major;
    try version1.addDiff(std.testing.allocator, DiffOp{
        .start_line = 0,
        .lines_removed = 1,
        .lines_added = 3,
        .removed = "old",
        .added = "new",
    });

    try cartridge.addVersion("src/test.zig", version1);

    const stats = try cartridge.computeStatistics("src/test.zig", .{});

    try std.testing.expectEqual(@as(u64, 1), stats.version_count);
    try std.testing.expectEqual(@as(u64, 3), stats.lines_added);
    try std.testing.expectEqual(@as(u64, 1), stats.lines_removed);
    try std.testing.expectEqual(@as(i64, 2), stats.net_change);
    try std.testing.expectEqual(@as(f64, 1.0), stats.impact_score);
}

test "DocumentHistoryCartridge.queryBlame" {
    var cartridge = try DocumentHistoryCartridge.init(std.testing.allocator, 100);
    defer cartridge.deinit();

    var version1 = try std.testing.allocator.create(DocumentVersion);
    version1.* = try DocumentVersion.init(std.testing.allocator, "v1", "alice");
    try version1.addDiff(std.testing.allocator, DiffOp{
        .start_line = 0,
        .lines_removed = 0,
        .lines_added = 5,
        .removed = "",
        .added = "line1\nline2\nline3\nline4\nline5",
    });

    try cartridge.addVersion("src/test.zig", version1);

    const result = try cartridge.queryBlame("src/test.zig", 3);

    try std.testing.expect(result != null);
    defer if (result) |r| r.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("alice", result.?.author);
    try std.testing.expectEqual(@as(u32, 5), result.?.lines_added);
}

test "DocumentHistoryCartridge.queryBySeverity" {
    var cartridge = try DocumentHistoryCartridge.init(std.testing.allocator, 100);
    defer cartridge.deinit();

    var version1 = try std.testing.allocator.create(DocumentVersion);
    version1.* = try DocumentVersion.init(std.testing.allocator, "v1", "alice");
    version1.severity = .critical;

    try cartridge.addVersion("src/test.zig", version1);

    var results = try cartridge.queryBySeverity(.critical);

    defer {
        for (results.items) |r| {
            _ = r;
        }
        results.deinit(std.testing.allocator);
    }

    try std.testing.expectEqual(@as(usize, 1), results.items.len);
}

test "DocumentHistoryCartridge.queryByTimeRange" {
    var cartridge = try DocumentHistoryCartridge.init(std.testing.allocator, 100);
    defer cartridge.deinit();

    var version1 = try std.testing.allocator.create(DocumentVersion);
    version1.* = try DocumentVersion.init(std.testing.allocator, "v1", "alice");
    version1.timestamp = 1000;

    var version2 = try std.testing.allocator.create(DocumentVersion);
    version2.* = try DocumentVersion.init(std.testing.allocator, "v2", "bob");
    version2.timestamp = 2000;

    try cartridge.addVersion("src/test.zig", version1);
    try cartridge.addVersion("src/main.zig", version2);

    var results = try cartridge.queryByTimeRange(500, 1500);

    defer {
        for (results.items) |r| {
            _ = r;
        }
        results.deinit(std.testing.allocator);
    }

    try std.testing.expectEqual(@as(usize, 1), results.items.len);
    try std.testing.expectEqual(@as(i64, 1000), results.items[0].timestamp);
}

// ==================== Change Impact Analysis Tests ====================

test "ChangeRisk.fromScore" {
    try std.testing.expectEqual(ChangeRisk.low, ChangeRisk.fromScore(0.1));
    try std.testing.expectEqual(ChangeRisk.medium, ChangeRisk.fromScore(0.4));
    try std.testing.expectEqual(ChangeRisk.high, ChangeRisk.fromScore(0.7));
    try std.testing.expectEqual(ChangeRisk.critical, ChangeRisk.fromScore(0.9));
}

test "ChangeRiskAnalysis.init and addRiskFactor" {
    var analysis = ChangeRiskAnalysis.init();
    defer analysis.deinit(std.testing.allocator);

    try analysis.addRiskFactor(std.testing.allocator, "test_factor", 0.5, "Test description");
    try analysis.addRecommendation(std.testing.allocator, "Test recommendation");

    analysis.risk_score = 0.7;
    analysis.updateRiskLevel();

    try std.testing.expectEqual(ChangeRisk.high, analysis.risk_level);
    try std.testing.expectEqual(@as(usize, 1), analysis.risk_factors.items.len);
    try std.testing.expectEqual(@as(usize, 1), analysis.recommendations.items.len);
}

test "DocumentHistoryIndex.analyzeChangeRisk - high risk change" {
    var index = DocumentHistoryIndex.init(std.testing.allocator);
    defer index.deinit();

    // Create multiple changes to increase risk score (>10 needed for frequency factor, >300 lines for size factor)
    var i: usize = 0;
    while (i < 30) : (i += 1) {
        var version = try std.testing.allocator.create(DocumentVersion);
        version.* = try DocumentVersion.init(std.testing.allocator, "v1", "alice");
        version.intent = .security;
        version.severity = .critical;
        version.timestamp = std.time.timestamp();
        try version.addDiff(std.testing.allocator, DiffOp{
            .start_line = 0,
            .lines_removed = 200,
            .lines_added = 250,
            .removed = "old",
            .added = "new",
        });
        try index.addVersion("src/security.zig", version);
    }

    var analysis = try index.analyzeChangeRisk("src/security.zig", "v1");
    defer analysis.deinit(std.testing.allocator);

    // Should have high or critical risk due to critical severity + security intent + high change frequency
    try std.testing.expect(analysis.risk_level == .high or analysis.risk_level == .critical);
    try std.testing.expect(analysis.risk_factors.items.len > 0);
}

test "DocumentHistoryIndex.analyzeChangeRisk - low risk change" {
    var index = DocumentHistoryIndex.init(std.testing.allocator);
    defer index.deinit();

    // Create a trivial documentation change
    var version = try std.testing.allocator.create(DocumentVersion);
    version.* = try DocumentVersion.init(std.testing.allocator, "v1", "alice");
    version.intent = .docs;
    version.severity = .trivial;
    version.timestamp = std.time.timestamp();
    try version.addDiff(std.testing.allocator, DiffOp{
        .start_line = 0,
        .lines_removed = 1,
        .lines_added = 2,
        .removed = "old",
        .added = "new",
    });

    try index.addVersion("README.md", version);

    var analysis = try index.analyzeChangeRisk("README.md", "v1");
    defer analysis.deinit(std.testing.allocator);

    // Should have low risk
    try std.testing.expectEqual(ChangeRisk.low, analysis.risk_level);
    try std.testing.expect(analysis.regression_probability < 0.3);
}

test "DocumentHistoryIndex.getHotFiles" {
    var index = DocumentHistoryIndex.init(std.testing.allocator);
    defer index.deinit();

    // Add multiple versions to one file to make it "hot"
    var i: usize = 0;
    while (i < 10) : (i += 1) {
        var version = try std.testing.allocator.create(DocumentVersion);
        version.* = try DocumentVersion.init(std.testing.allocator, "v1", "alice");
        version.severity = .major;
        version.timestamp = @intCast(1000 + i * 100);
        try version.addDiff(std.testing.allocator, DiffOp{
            .start_line = 0,
            .lines_removed = 1,
            .lines_added = 1,
            .removed = "old",
            .added = "new",
        });
        try index.addVersion("src/hot.zig", version);
    }

    // Add one version to another file
    const version2 = try std.testing.allocator.create(DocumentVersion);
    version2.* = try DocumentVersion.init(std.testing.allocator, "v2", "bob");
    try index.addVersion("src/cold.zig", version2);

    var hot_files = try index.getHotFiles(10);
    defer {
        for (hot_files.items) |*f| f.deinit(std.testing.allocator);
        hot_files.deinit(std.testing.allocator);
    }

    // Should return hot.zig first (highest change frequency)
    try std.testing.expect(hot_files.items.len > 0);
    try std.testing.expectEqualStrings("src/hot.zig", hot_files.items[0].file_path);
    try std.testing.expect(hot_files.items[0].change_count == 10);
}

test "DocumentHistoryIndex.calculateChurnMetrics" {
    var index = DocumentHistoryIndex.init(std.testing.allocator);
    defer index.deinit();

    // Add high-churn file
    var i: usize = 0;
    while (i < 5) : (i += 1) {
        var version = try std.testing.allocator.create(DocumentVersion);
        version.* = try DocumentVersion.init(std.testing.allocator, "v1", "alice");
        try version.addDiff(std.testing.allocator, DiffOp{
            .start_line = 0,
            .lines_removed = 10,
            .lines_added = 20,
            .removed = "old",
            .added = "new",
        });
        try index.addVersion("src/high_churn.zig", version);
    }

    // Add low-churn file
    const version2 = try std.testing.allocator.create(DocumentVersion);
    version2.* = try DocumentVersion.init(std.testing.allocator, "v2", "bob");
    try version2.addDiff(std.testing.allocator, DiffOp{
        .start_line = 0,
        .lines_removed = 0,
        .lines_added = 1,
        .removed = "",
        .added = "new",
    });
    try index.addVersion("src/low_churn.zig", version2);

    var metrics = try index.calculateChurnMetrics();
    defer metrics.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u64, 2), metrics.total_files);
    try std.testing.expect(metrics.directory_churn.items.len > 0);
}

test "DocumentHistoryIndex.predictImpact - critical proposed change" {
    var index = DocumentHistoryIndex.init(std.testing.allocator);
    defer index.deinit();

    // Add some history
    var i: usize = 0;
    while (i < 5) : (i += 1) {
        var version = try std.testing.allocator.create(DocumentVersion);
        version.* = try DocumentVersion.init(std.testing.allocator, "v1", "alice");
        version.intent = .security;
        version.severity = .critical;
        try index.addVersion("src/auth.zig", version);
    }

    var prediction = try index.predictImpact(
        "src/auth.zig",
        .critical,
        .security,
        500
    );
    defer prediction.deinit(std.testing.allocator);

    // Should predict high risk
    try std.testing.expect(prediction.predicted_risk == .high or prediction.predicted_risk == .critical);
    try std.testing.expect(prediction.confidence > 0.0);
    try std.testing.expect(prediction.testing_recommendations.items.len > 0);
}

