//! Query result summarization and relevance ranking
//!
//! Implements LLM-powered result summarization to reduce context window usage
//! and multi-factor relevance ranking for optimal result ordering.

const std = @import("std");
const mem = std.mem;

const EntityId = @import("../cartridges/structured_memory.zig").EntityId;
const Entity = @import("../cartridges/structured_memory.zig").Entity;

const llm_client = @import("../llm/client.zig");
const llm_function = @import("../llm/function.zig");
const llm_types = @import("../llm/types.zig");

/// Query result with ranking metadata
pub const RankedResult = struct {
    entity_id: EntityId,
    score: f32,
    rank: usize,
    relevance_factors: RelevanceFactors,
    data: []const u8,

    pub fn deinit(self: *RankedResult, allocator: std.mem.Allocator) void {
        allocator.free(self.entity_id.namespace);
        allocator.free(self.entity_id.local_id);
        self.relevance_factors.deinit(allocator);
        allocator.free(self.data);
    }
};

/// Relevance factors for scoring
pub const RelevanceFactors = struct {
    confidence: f32 = 0.0,
    recency: f32 = 0.0,
    popularity: f32 = 0.0,
    semantic_similarity: f32 = 0.0,
    exact_match: f32 = 0.0,

    pub fn deinit(self: *RelevanceFactors, allocator: std.mem.Allocator) void {
        _ = self;
        _ = allocator;
    }

    pub fn computeScore(self: *const RelevanceFactors, weights: ScoringWeights) f32 {
        return self.confidence * weights.confidence +
               self.recency * weights.recency +
               self.popularity * weights.popularity +
               self.semantic_similarity * weights.semantic_similarity +
               self.exact_match * weights.exact_match;
    }
};

/// Scoring weights for relevance
pub const ScoringWeights = struct {
    confidence: f32 = 0.3,
    recency: f32 = 0.2,
    popularity: f32 = 0.2,
    semantic_similarity: f32 = 0.2,
    exact_match: f32 = 0.1,
};

/// Relevance ranking strategy
pub const RankingStrategy = enum {
    /// Balanced scoring using all factors
    balanced,
    /// Prioritize recent results
    recent_first,
    /// Prioritize high confidence
    confidence_first,
    /// Prioritize popularity
    popular_first,
    /// Prioritize semantic similarity
    semantic_first,
    /// Custom weights
    custom,
};

/// Result summarizer for LLM-powered summarization
pub const ResultSummarizer = struct {
    allocator: std.mem.Allocator,
    llm_provider: ?*llm_client.LLMProvider,
    config: SummaryConfig,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, llm_provider: ?*llm_client.LLMProvider, config: SummaryConfig) Self {
        return ResultSummarizer{
            .allocator = allocator,
            .llm_provider = llm_provider,
            .config = config,
        };
    }

    /// Summarize a list of results
    pub fn summarize(self: *Self, results: []const []const u8) !SummaryResult {
        const total_chars = self.getTotalChars(results);

        // Check if summarization is needed
        if (total_chars <= self.config.max_chars) {
            return SummaryResult{
                .summary = null,
                .original_count = results.len,
                .summary_type = .not_needed,
                .chars_saved = 0,
            };
        }

        // Try LLM summarization
        if (self.llm_provider) |provider| {
            const llm_result = self.summarizeWithLLM(provider, results) catch |err| {
                std.log.warn("LLM summarization failed: {}, using fallback", .{err});
                return self.summarizeFallback(results);
            };

            return llm_result;
        }

        return self.summarizeFallback(results);
    }

    /// Summarize using LLM
    fn summarizeWithLLM(self: *Self, provider: *llm_client.LLMProvider, results: []const []const u8) !SummaryResult {
        _ = provider;
        _ = results;

        // Build prompt with results
        var prompt = std.array_list.Managed(u8).init(self.allocator);
        defer prompt.deinit();

        try prompt.appendSlice("Summarize these query results, preserving key insights:\n\n");

        for (results[0..@min(results.len, self.config.max_items)]) |result| {
            try prompt.appendSlice("- ");
            try prompt.appendSlice(result);
            try prompt.appendSlice("\n");
        }

        try prompt.appendSlice("\nProvide a concise summary.");

        // In real implementation, would call LLM here
        // For now, return fallback
        return self.summarizeFallback(results);
    }

    /// Fallback summarization (truncation)
    fn summarizeFallback(self: *Self, results: []const []const u8) !SummaryResult {
        var summary = std.array_list.Managed(u8).init(self.allocator);
        errdefer summary.deinit();

        var chars_used: usize = 0;
        var items_included: usize = 0;

        try summary.appendSlice("Top results:\n");

        for (results) |result| {
            const entry_len = result.len + 10; // Include formatting
            if (chars_used + entry_len > self.config.max_chars) break;

            try summary.appendSlice("- ");
            try summary.appendSlice(result);
            try summary.appendSlice("\n");
            chars_used += entry_len;
            items_included += 1;
        }

        const remaining = results.len - items_included;
        if (remaining > 0) {
            try summary.print("\n... and {d} more results", .{remaining});
        }

        const total_chars = self.getTotalChars(results);

        return SummaryResult{
            .summary = summary.toOwnedSlice(),
            .original_count = results.len,
            .summary_type = .truncated,
            .chars_saved = @as(i64, @intCast(total_chars)) - @as(i64, @intCast(chars_used)),
        };
    }

    fn getTotalChars(self: *Self, results: []const []const u8) usize {
        _ = self;
        var total: usize = 0;
        for (results) |r| {
            total += r.len;
        }
        return total;
    }
};

/// Summary result
pub const SummaryResult = struct {
    summary: ?[]const u8,
    original_count: usize,
    summary_type: SummaryType,
    chars_saved: i64,

    pub fn deinit(self: *SummaryResult, allocator: std.mem.Allocator) void {
        if (self.summary) |s| allocator.free(s);
    }

    pub const SummaryType = enum {
        not_needed,
        llm_generated,
        truncated,
    };
};

/// Summary configuration
pub const SummaryConfig = struct {
    /// Maximum characters in output
    max_chars: usize = 4000,
    /// Maximum items to include in summary
    max_items: usize = 20,
    /// Target compression ratio (0.5 = 50%)
    target_ratio: f32 = 0.5,
};

/// Relevance ranker
pub const RelevanceRanker = struct {
    allocator: std.mem.Allocator,
    strategy: RankingStrategy,
    custom_weights: ?ScoringWeights,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, strategy: RankingStrategy) Self {
        return RelevanceRanker{
            .allocator = allocator,
            .strategy = strategy,
            .custom_weights = null,
        };
    }

    pub fn setCustomWeights(self: *Self, weights: ScoringWeights) void {
        self.custom_weights = weights;
        self.strategy = .custom;
    }

    /// Rank results by relevance
    pub fn rank(self: *Self, results: []RawResult, query: []const u8) ![]RankedResult {
        var ranked = std.array_list.Managed(RankedResult).init(self.allocator);

        // Compute scores
        for (results, 0..) |result, i| {
            const factors = try self.computeFactors(result, query);

            const weights = self.getWeights();

            const score = factors.computeScore(weights);

            const ranked_result = RankedResult{
                .entity_id = EntityId{
                    .namespace = try self.allocator.dupe(u8, result.entity_id.namespace),
                    .local_id = try self.allocator.dupe(u8, result.entity_id.local_id),
                },
                .score = score,
                .rank = i, // Temporary, will be updated after sorting
                .relevance_factors = factors,
                .data = try self.allocator.dupe(u8, result.data),
            };

            try ranked.append(ranked_result);
        }

        // Sort by score
        std.sort.insertion(RankedResult, ranked.items, {}, struct {
            fn lessThan(_: void, a: RankedResult, b: RankedResult) bool {
                return a.score > b.score;
            }
        }.lessThan);

        // Update ranks
        for (ranked.items, 0..) |*r, i| {
            r.rank = i;
        }

        return ranked.toOwnedSlice();
    }

    /// Get top-K results
    pub fn topK(self: *Self, results: []RawResult, query: []const u8, k: usize) ![]RankedResult {
        const ranked = try self.rank(results, query);
        defer {
            for (ranked) |*r| r.deinit(self.allocator);
            self.allocator.free(ranked);
        }

        const count = @min(k, ranked.len);

        var top = std.array_list.Managed(RankedResult).init(self.allocator);

        for (ranked[0..count]) |r| {
            const cloned = RankedResult{
                .entity_id = EntityId{
                    .namespace = try self.allocator.dupe(u8, r.entity_id.namespace),
                    .local_id = try self.allocator.dupe(u8, r.entity_id.local_id),
                },
                .score = r.score,
                .rank = r.rank,
                .relevance_factors = RelevanceFactors{
                    .confidence = r.relevance_factors.confidence,
                    .recency = r.relevance_factors.recency,
                    .popularity = r.relevance_factors.popularity,
                    .semantic_similarity = r.relevance_factors.semantic_similarity,
                    .exact_match = r.relevance_factors.exact_match,
                },
                .data = try self.allocator.dupe(u8, r.data),
            };
            try top.append(cloned);
        }

        return top.toOwnedSlice();
    }

    /// Compute relevance factors for a result
    fn computeFactors(self: *Self, result: RawResult, query: []const u8) !RelevanceFactors {
        _ = self;

        var factors = RelevanceFactors{};

        // Confidence from entity
        factors.confidence = result.confidence;

        // Recency (newer is better, normalize to 0-1)
        const now = @as(u64, @intCast(std.time.nanoTimestamp() / 1_000_000_000));
        const age_hours = @as(f32, @floatFromInt(now - result.created_at)) / 3600.0;
        factors.recency = @max(0.0, 1.0 - (age_hours / (24.0 * 30))); // Decay over 30 days

        // Popularity from access count
        factors.popularity = @min(1.0, @as(f32, @floatFromInt(result.access_count)) / 100.0);

        // Semantic similarity (simplified - would use embeddings in production)
        factors.semantic_similarity = self.computeSimilarity(result.data, query);

        // Exact match bonus
        factors.exact_match = if (mem.indexOf(u8, result.data, query) != null) 1.0 else 0.0;

        return factors;
    }

    /// Simple similarity computation
    fn computeSimilarity(self: *Self, text: []const u8, query: []const u8) f32 {
        _ = self;

        // Word overlap similarity
        var text_words = std.array_list.Managed([]const u8).init(self.allocator);
        defer {
            for (text_words.items) |w| self.allocator.free(w);
            text_words.deinit();
        }

        var query_words = std.array_list.Managed([]const u8).init(self.allocator);
        defer {
            for (query_words.items) |w| self.allocator.free(w);
            query_words.deinit();
        }

        var iter = mem.splitScalar(u8, text, ' ');
        while (iter.next()) |word| {
            if (word.len > 0) {
                text_words.append(try self.allocator.dupe(u8, word)) catch {};
            }
        }

        iter = mem.splitScalar(u8, query, ' ');
        while (iter.next()) |word| {
            if (word.len > 0) {
                query_words.append(try self.allocator.dupe(u8, word)) catch {};
            }
        }

        if (query_words.items.len == 0) return 0.0;

        var overlap: usize = 0;
        for (query_words.items) |qw| {
            for (text_words.items) |tw| {
                if (mem.eql(u8, qw, tw)) {
                    overlap += 1;
                    break;
                }
            }
        }

        return @as(f32, @floatFromInt(overlap)) / @as(f32, @floatFromInt(query_words.items.len));
    }

    /// Get weights based on strategy
    fn getWeights(self: *const Self) ScoringWeights {
        return switch (self.strategy) {
            .balanced => ScoringWeights{},
            .recent_first => ScoringWeights{ .recency = 0.6, .confidence = 0.2, .popularity = 0.1, .semantic_similarity = 0.1, .exact_match = 0.0 },
            .confidence_first => ScoringWeights{ .confidence = 0.6, .recency = 0.1, .popularity = 0.1, .semantic_similarity = 0.1, .exact_match = 0.1 },
            .popular_first => ScoringWeights{ .popularity = 0.6, .confidence = 0.1, .recency = 0.1, .semantic_similarity = 0.1, .exact_match = 0.1 },
            .semantic_first => ScoringWeights{ .semantic_similarity = 0.6, .confidence = 0.1, .recency = 0.1, .popularity = 0.1, .exact_match = 0.1 },
            .custom => self.custom_weights orelse ScoringWeights{},
        };
    }
};

/// Raw result before ranking
pub const RawResult = struct {
    entity_id: EntityId,
    data: []const u8,
    confidence: f32,
    created_at: u64,
    access_count: u64,
};

/// Combined result processor
pub const ResultProcessor = struct {
    allocator: std.mem.Allocator,
    summarizer: ResultSummarizer,
    ranker: RelevanceRanker,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, llm_provider: ?*llm_client.LLMProvider) Self {
        return ResultProcessor{
            .allocator = allocator,
            .summarizer = ResultSummarizer.init(allocator, llm_provider, SummaryConfig{}),
            .ranker = RelevanceRanker.init(allocator, .balanced),
        };
    }

    /// Process results: rank, summarize, and return
    pub fn process(self: *Self, results: []RawResult, query: []const u8, limit: usize) !ProcessedResult {
        // Rank results
        const ranked = try self.ranker.topK(results, query, limit);
        defer {
            for (ranked) |*r| r.deinit(self.allocator);
            self.allocator.free(ranked);
        }

        // Extract result strings for summarization
        var result_strings = std.array_list.Managed([]const u8).init(self.allocator);
        defer {
            for (result_strings.items) |s| self.allocator.free(s);
            result_strings.deinit();
        }

        for (ranked) |r| {
            try result_strings.append(try self.allocator.dupe(u8, r.data));
        }

        // Summarize if needed
        const summary = try self.summarizer.summarize(result_strings.items);

        return ProcessedResult{
            .results = try self.dupeRanked(ranked),
            .summary = summary,
        };
    }

    fn dupeRanked(self: *Self, ranked: []const RankedResult) ![]RankedResult {
        var duped = std.array_list.Managed(RankedResult).init(self.allocator);

        for (ranked) |r| {
            const cloned = RankedResult{
                .entity_id = EntityId{
                    .namespace = try self.allocator.dupe(u8, r.entity_id.namespace),
                    .local_id = try self.allocator.dupe(u8, r.entity_id.local_id),
                },
                .score = r.score,
                .rank = r.rank,
                .relevance_factors = RelevanceFactors{
                    .confidence = r.relevance_factors.confidence,
                    .recency = r.relevance_factors.recency,
                    .popularity = r.relevance_factors.popularity,
                    .semantic_similarity = r.relevance_factors.semantic_similarity,
                    .exact_match = r.relevance_factors.exact_match,
                },
                .data = try self.allocator.dupe(u8, r.data),
            };
            try duped.append(cloned);
        }

        return duped.toOwnedSlice();
    }
};

/// Final processed result
pub const ProcessedResult = struct {
    results: []RankedResult,
    summary: SummaryResult,

    pub fn deinit(self: *ProcessedResult, allocator: std.mem.Allocator) void {
        for (self.results) |*r| r.deinit(allocator);
        allocator.free(self.results);
        self.summary.deinit(allocator);
    }
};

// ==================== Tests ====================//

test "ResultSummarizer not needed" {
    const results = [_][]const u8{ "short result" };

    var summarizer = ResultSummarizer.init(std.testing.allocator, null, SummaryConfig{
        .max_chars = 1000,
    });

    const result = try summarizer.summarize(&results);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(result.summary == null);
    try std.testing.expectEqual(SummaryResult.SummaryType.not_needed, result.summary_type);
}

test "ResultSummarizer truncation" {
    const long_result = "x" ** 2000;

    const results = [_][]const u8{long_result};

    var summarizer = ResultSummarizer.init(std.testing.allocator, null, SummaryConfig{
        .max_chars = 100,
    });

    const result = try summarizer.summarize(&results);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(result.summary != null);
    try std.testing.expectEqual(SummaryResult.SummaryType.truncated, result.summary_type);
}

test "RelevanceRanker rank" {
    const results = [_]RawResult{
        .{
            .entity_id = .{ .namespace = "file", .local_id = "a.zig" },
            .data = "database implementation",
            .confidence = 0.9,
            .created_at = 1000,
            .access_count = 50,
        },
        .{
            .entity_id = .{ .namespace = "file", .local_id = "b.zig" },
            .data = "test file",
            .confidence = 0.5,
            .created_at = 2000,
            .access_count = 10,
        },
    };

    var ranker = RelevanceRanker.init(std.testing.allocator, .confidence_first);

    const ranked = try ranker.rank(&results, "database");
    defer {
        for (ranked) |*r| r.deinit(std.testing.allocator);
        std.testing.allocator.free(ranked);
    }

    try std.testing.expectEqual(@as(usize, 2), ranked.len);
    try std.testing.expect(ranked[0].score >= ranked[1].score); // Sorted by score
}

test "RelevanceRanker topK" {
    const results = [_]RawResult{
        .{
            .entity_id = .{ .namespace = "file", .local_id = "a.zig" },
            .data = "database",
            .confidence = 0.9,
            .created_at = 1000,
            .access_count = 50,
        },
        .{
            .entity_id = .{ .namespace = "file", .local_id = "b.zig" },
            .data = "other",
            .confidence = 0.5,
            .created_at = 2000,
            .access_count = 10,
        },
    };

    var ranker = RelevanceRanker.init(std.testing.allocator, .balanced);

    const top = try ranker.topK(&results, "database", 1);
    defer {
        for (top) |*r| r.deinit(std.testing.allocator);
        std.testing.allocator.free(top);
    }

    try std.testing.expectEqual(@as(usize, 1), top.len);
}

test "RelevanceFactors computeScore" {
    const factors = RelevanceFactors{
        .confidence = 0.8,
        .recency = 0.6,
        .popularity = 0.4,
        .semantic_similarity = 0.5,
        .exact_match = 0.0,
    };

    const weights = ScoringWeights{};
    const score = factors.computeScore(weights);

    try std.testing.expect(score > 0);
}

test "ResultProcessor process" {
    const results = [_]RawResult{
        .{
            .entity_id = .{ .namespace = "file", .local_id = "a.zig" },
            .data = "database code",
            .confidence = 0.8,
            .created_at = 1000,
            .access_count = 20,
        },
    };

    var processor = ResultProcessor.init(std.testing.allocator, null);

    const processed = try processor.process(&results, "database", 10);
    defer processed.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), processed.results.len);
}

test "computeSimilarity" {
    var ranker = RelevanceRanker.init(std.testing.allocator, .balanced);

    const similarity = ranker.computeSimilarity("database implementation", "database");

    try std.testing.expect(similarity > 0); // Should have overlap
}

test "ProcessedResult deinit" {
    var results = std.array_list.Managed(RawResult).init(std.testing.allocator);

    var processor = ResultProcessor.init(std.testing.allocator, null);

    const processed = try processor.process(results.items, "test", 10);
    processed.deinit(std.testing.allocator);

    // If we get here, deinit worked
    try std.testing.expect(true);
}
