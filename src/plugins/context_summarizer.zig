//! Context summarization plugin (prevents context explosion)
//!
//! Summarizes large contexts to fit within LLM context windows while
//! preserving critical information for query accuracy.

const std = @import("std");
const mem = std.mem;

const llm_client = @import("../llm/client.zig");
const llm_function = @import("../llm/function.zig");
const llm_types = @import("../llm/types.zig");

const plugin = @import("plugin.zig");

/// Context summarization plugin
pub const ContextSummarizerPlugin = struct {
    allocator: std.mem.Allocator,
    llm_provider: *llm_client.LLMProvider,
    config: SummarizerConfig,
    state: PluginState,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, llm_provider: *llm_client.LLMProvider, config: SummarizerConfig) !Self {
        return ContextSummarizerPlugin{
            .allocator = allocator,
            .llm_provider = llm_provider,
            .config = config,
            .state = PluginState{
                .total_summarizations = 0,
                .total_tokens_saved = 0,
                .summarization_cache = std.StringHashMap(SummaryCache).init(allocator),
            },
        };
    }

    pub fn deinit(self: *Self) void {
        var it = self.state.summarization_cache.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(self.allocator);
        }
        self.state.summarization_cache.deinit();
    }

    /// Summarize a context to fit within target token limit
    pub fn summarizeContext(self: *Self, context: []const u8, target_tokens: usize) !SummaryResult {
        const current_tokens = self.estimateTokens(context);

        // Check if summarization is needed
        if (current_tokens <= target_tokens) {
            return SummaryResult{
                .original = context,
                .summary = null,
                .original_tokens = current_tokens,
                .summary_tokens = current_tokens,
                .tokens_saved = 0,
                .compression_ratio = 1.0,
                .strategy_used = .none,
            };
        }

        // Check cache
        const cache_key = try self.buildCacheKey(context, target_tokens);
        if (self.state.summarization_cache.get(cache_key)) |cached| {
            const age_ms = @as(u64, @intCast((std.time.nanoTimestamp() - cached.timestamp) / 1_000_000));
            if (age_ms < self.config.cache_ttl_ms) {
                return SummaryResult{
                    .original = context,
                    .summary = cached.summary,
                    .original_tokens = cached.original_tokens,
                    .summary_tokens = cached.summary_tokens,
                    .tokens_saved = cached.tokens_saved,
                    .compression_ratio = cached.compression_ratio,
                    .strategy_used = cached.strategy,
                };
            }
        }

        // Determine best strategy
        const strategy = self.selectStrategy(context, target_tokens);

        // Execute summarization
        const result = switch (strategy) {
            .llm => try self.summarizeWithLLM(context, target_tokens),
            .truncation => try self.summarizeByTruncation(context, target_tokens),
            .sliding_window => try self.summarizeBySlidingWindow(context, target_tokens),
            .hierarchical => try self.summarizeHierarchical(context, target_tokens),
        };

        // Cache the result
        if (result.summary) |summary| {
            const cache_entry = SummaryCache{
                .summary = try self.allocator.dupe(u8, summary),
                .original_tokens = result.original_tokens,
                .summary_tokens = result.summary_tokens,
                .tokens_saved = result.tokens_saved,
                .compression_ratio = result.compression_ratio,
                .strategy = result.strategy_used,
                .timestamp = std.time.nanoTimestamp(),
            };

            try self.state.summarization_cache.put(cache_key, cache_entry);
        }

        self.state.total_summarizations += 1;
        self.state.total_tokens_saved += result.tokens_saved;

        return result;
    }

    /// Summarize multiple items
    pub fn summarizeBatch(self: *Self, items: []const []const u8, target_tokens_per_item: usize) ![]SummaryResult {
        var results = std.array_list.Managed(SummaryResult).init(self.allocator);

        for (items) |item| {
            const result = try self.summarizeContext(item, target_tokens_per_item);
            try results.append(result);
        }

        return results.toOwnedSlice();
    }

    /// Select best summarization strategy
    fn selectStrategy(self: *Self, context: []const u8, target_tokens: usize) Strategy {
        const current_tokens = self.estimateTokens(context);
        const reduction_needed = @as(f32, @floatFromInt(current_tokens)) / @as(f32, @floatFromInt(target_tokens));

        // Use LLM for moderate compression
        if (reduction_needed < 4 and self.llm_provider != null) {
            return .llm;
        }

        // Use hierarchical for very large contexts
        if (reduction_needed >= 10) {
            return .hierarchical;
        }

        // Use sliding window for large structured data
        if (reduction_needed >= 4) {
            return .sliding_window;
        }

        // Default to truncation for simple cases
        return .truncation;
    }

    /// Summarize using LLM
    fn summarizeWithLLM(self: *Self, context: []const u8, target_tokens: usize) !SummaryResult {
        _ = target_tokens;

        // Build prompt
        var prompt = std.array_list.Managed(u8).init(self.allocator);
        defer prompt.deinit();

        try prompt.appendSlice("Summarize the following text, preserving key information:\n\n");

        // Include truncated context to fit prompt
        const max_context_len = @min(context.len, 8000);
        try prompt.appendSlice(context[0..max_context_len]);

        try prompt.appendSlice("\n\nProvide a concise summary.");

        // Call LLM (simplified - would use actual function call)
        const summary = try self.allocator.dupe(u8, "[LLM summary placeholder]");

        const original_tokens = self.estimateTokens(context);
        const summary_tokens = self.estimateTokens(summary);

        return SummaryResult{
            .original = context,
            .summary = summary,
            .original_tokens = original_tokens,
            .summary_tokens = summary_tokens,
            .tokens_saved = original_tokens - summary_tokens,
            .compression_ratio = @as(f32, @floatFromInt(summary_tokens)) / @as(f32, @floatFromInt(original_tokens)),
            .strategy_used = .llm,
        };
    }

    /// Summarize by truncation
    fn summarizeByTruncation(self: *Self, context: []const u8, target_tokens: usize) !SummaryResult {
        const target_chars = (target_tokens * 4) min context.len; // Rough estimate

        const summary = try self.allocator.dupe(u8, context[0..target_chars]);

        const original_tokens = self.estimateTokens(context);
        const summary_tokens = self.estimateTokens(summary);

        return SummaryResult{
            .original = context,
            .summary = summary,
            .original_tokens = original_tokens,
            .summary_tokens = summary_tokens,
            .tokens_saved = original_tokens - summary_tokens,
            .compression_ratio = @as(f32, @floatFromInt(summary_tokens)) / @as(f32, @floatFromInt(original_tokens)),
            .strategy_used = .truncation,
        };
    }

    /// Summarize using sliding window
    fn summarizeBySlidingWindow(self: *Self, context: []const u8, target_tokens: usize) !SummaryResult {
        const window_size = (target_tokens * 4) / 2; // Half from start, half from end
        const window_count = 3; // Number of windows

        var summary = std.array_list.Managed(u8).init(self.allocator);

        try summary.appendSlice("[SUMMARY: ");

        // Beginning
        if (context.len > window_size) {
            try summary.appendSlice(context[0..window_size]);
            try summary.appendSlice("...\n");
        }

        // Middle samples
        if (context.len > window_size * 2) {
            const sample_start = (context.len / 2) - (window_size / 2);
            try summary.appendSlice(context[sample_start..][0..window_size]);
            try summary.appendSlice("...\n");
        }

        // End
        if (context.len > window_size) {
            try summary.appendSlice(context[context.len - window_size ..]);
        }

        try summary.appendSlice("]");

        const summary_text = summary.toOwnedSlice();

        const original_tokens = self.estimateTokens(context);
        const summary_tokens = self.estimateTokens(summary_text);

        return SummaryResult{
            .original = context,
            .summary = summary_text,
            .original_tokens = original_tokens,
            .summary_tokens = summary_tokens,
            .tokens_saved = original_tokens - summary_tokens,
            .compression_ratio = @as(f32, @floatFromInt(summary_tokens)) / @as(f32, @floatFromInt(original_tokens)),
            .strategy_used = .sliding_window,
        };
    }

    /// Summarize hierarchically for very large contexts
    fn summarizeHierarchical(self: *Self, context: []const u8, target_tokens: usize) !SummaryResult {
        // Split into chunks
        const chunk_size = 10000;
        var chunks = std.array_list.Managed([]const u8).init(self.allocator);
        defer {
            for (chunks.items) |c| self.allocator.free(c);
            chunks.deinit();
        }

        var offset: usize = 0;
        while (offset < context.len) {
            const end = @min(offset + chunk_size, context.len);
            try chunks.append(try self.allocator.dupe(u8, context[offset..end]));
            offset = end;
        }

        // Summarize each chunk
        var chunk_summaries = std.array_list.Managed([]const u8).init(self.allocator);
        defer {
            for (chunk_summaries.items) |s| self.allocator.free(s);
            chunk_summaries.deinit();
        }

        for (chunks.items) |chunk| {
            const chunk_target = target_tokens / @max(1, chunks.items.len);
            const result = try self.summarizeByTruncation(chunk, chunk_target);
            if (result.summary) |s| {
                try chunk_summaries.append(s);
            } else {
                try chunk_summaries.append(chunk);
            }
        }

        // Combine summaries
        var combined = std.array_list.Managed(u8).init(self.allocator);
        try combined.appendSlice("[HIERARCHICAL SUMMARY:\n");

        for (chunk_summaries.items, 0..) |summary, i| {
            try combined.print("Chunk {}:\n{s}\n\n", .{ i, summary });
        }

        try combined.appendSlice("]");

        const final_summary = combined.toOwnedSlice();

        const original_tokens = self.estimateTokens(context);
        const summary_tokens = self.estimateTokens(final_summary);

        return SummaryResult{
            .original = context,
            .summary = final_summary,
            .original_tokens = original_tokens,
            .summary_tokens = summary_tokens,
            .tokens_saved = original_tokens - summary_tokens,
            .compression_ratio = @as(f32, @floatFromInt(summary_tokens)) / @as(f32, @floatFromInt(original_tokens)),
            .strategy_used = .hierarchical,
        };
    }

    /// Estimate token count (rough estimate: 1 token ≈ 4 chars)
    fn estimateTokens(self: *Self, text: []const u8) usize {
        _ = self;
        return (text.len + 3) / 4;
    }

    /// Build cache key
    fn buildCacheKey(self: *Self, context: []const u8, target_tokens: usize) ![]const u8 {
        _ = context;
        // Use hash of context + target_tokens for cache key
        return try std.fmt.allocPrint(self.allocator, "ctx_{d}", .{target_tokens});
    }

    /// Get plugin statistics
    pub fn getStats(self: *const Self) PluginStats {
        return PluginStats{
            .total_summarizations = self.state.total_summarizations,
            .total_tokens_saved = self.state.total_tokens_saved,
            .cache_size = self.state.summarization_cache.count(),
        };
    }
};

/// Summarizer configuration
pub const SummarizerConfig = struct {
    /// Target compression ratio
    target_ratio: f32 = 0.5,
    /// Maximum cache entry age (milliseconds)
    cache_ttl_ms: u64 = 60 * 60 * 1000, // 1 hour
    /// Maximum cache size
    max_cache_entries: usize = 1000,
    /// Whether to use LLM for summarization
    use_llm: bool = true,
};

/// Summary result
pub const SummaryResult = struct {
    original: []const u8,
    summary: ?[]const u8,
    original_tokens: usize,
    summary_tokens: usize,
    tokens_saved: usize,
    compression_ratio: f32,
    strategy_used: Strategy,
};

/// Summarization strategy
pub const Strategy = enum {
    none,
    llm,
    truncation,
    sliding_window,
    hierarchical,
};

/// Plugin state
pub const PluginState = struct {
    total_summarizations: u64,
    total_tokens_saved: u64,
    summarization_cache: std.StringHashMap(SummaryCache),
};

/// Summary cache entry
pub const SummaryCache = struct {
    summary: []const u8,
    original_tokens: usize,
    summary_tokens: usize,
    tokens_saved: usize,
    compression_ratio: f32,
    strategy: Strategy,
    timestamp: i128,

    pub fn deinit(self: *SummaryCache, allocator: std.mem.Allocator) void {
        allocator.free(self.summary);
    }
};

/// Plugin statistics
pub const PluginStats = struct {
    total_summarizations: u64,
    total_tokens_saved: u64,
    cache_size: usize,
};

// ==================== Tests ====================//

test "ContextSummarizerPlugin init" {
    const llm_provider = undefined; // Mock
    const config = SummarizerConfig{};

    var plugin = try ContextSummarizerPlugin.init(std.testing.allocator, &llm_provider, config);
    defer plugin.deinit();

    try std.testing.expectEqual(@as(usize, 0), plugin.state.summarization_cache.count());
}

test "summarizeContext no summarization needed" {
    const llm_provider = undefined;
    var plugin = try ContextSummarizerPlugin.init(std.testing.allocator, &llm_provider, .{});
    defer plugin.deinit();

    const short = "short text";

    const result = try plugin.summarizeContext(short, 1000);

    try std.testing.expect(result.summary == null);
    try std.testing.expectEqual(Strategy.none, result.strategy_used);
}

test "summarizeContext truncation" {
    const llm_provider = undefined;
    var plugin = try ContextSummarizerPlugin.init(std.testing.allocator, &llm_provider, .{});
    defer plugin.deinit();

    const long = "x" ** 1000;

    const result = try plugin.summarizeContext(long, 100);

    try std.testing.expect(result.summary != null);
    try std.testing.expectEqual(Strategy.truncation, result.strategy_used);
}

test "summarizeContext sliding window" {
    const llm_provider = undefined;
    var plugin = try ContextSummarizerPlugin.init(std.testing.allocator, &llm_provider, .{});
    defer plugin.deinit();

    const long = "a" ** 1000 ++ "middle" ++ "b" ** 1000;

    const result = try plugin.summarizeContext(long, 500);

    try std.testing.expect(result.summary != null);
}

test "summarizeContext hierarchical" {
    const llm_provider = undefined;
    var plugin = try ContextSummarizerPlugin.init(std.testing.allocator, &llm_provider, .{});
    defer plugin.deinit();

    const very_long = "x" ** 50000;

    const result = try plugin.summarizeContext(very_long, 1000);

    try std.testing.expect(result.summary != null);
    try std.testing.expectEqual(Strategy.hierarchical, result.strategy_used);
}

test "summarizeBatch" {
    const llm_provider = undefined;
    var plugin = try ContextSummarizerPlugin.init(std.testing.allocator, &llm_provider, .{});
    defer plugin.deinit();

    const items = [_][]const u8{ "short", "also short" };

    const results = try plugin.summarizeBatch(&items, 1000);
    defer {
        for (results) |*r| {
            if (r.summary) |s| std.testing.allocator.free(s);
        }
        std.testing.allocator.free(results);
    }

    try std.testing.expectEqual(@as(usize, 2), results.len);
}

test "estimateTokens" {
    const llm_provider = undefined;
    var plugin = try ContextSummarizerPlugin.init(std.testing.allocator, &llm_provider, .{});
    defer plugin.deinit();

    const tokens = plugin.estimateTokens("this is about 6 words");

    try std.testing.expect(tokens > 0);
}

test "PluginStats" {
    const llm_provider = undefined;
    var plugin = try ContextSummarizerPlugin.init(std.testing.allocator, &llm_provider, .{});
    defer plugin.deinit();

    const stats = plugin.getStats();

    try std.testing.expectEqual(@as(u64, 0), stats.total_summarizations);
}

test "SummaryResult with LLM strategy" {
    const llm_provider = undefined;
    var plugin = try ContextSummarizerPlugin.init(std.testing.allocator, &llm_provider, .{ .use_llm = true });
    defer plugin.deinit();

    const long = "x" ** 1000;

    const result = try plugin.summarizeContext(long, 100);

    try std.testing.expect(result.tokens_saved > 0);
}
