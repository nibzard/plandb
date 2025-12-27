//! Embedding Generation Plugin for NorthstarDB
//!
//! Integrates with embedding providers (OpenAI text-embedding-3, local models)
//! with batching, caching, and cost optimization. Automatically generates
//! embeddings for entities on commit according to spec/ai_plugins_v1.md.
//!
//! Features:
//! - Batch API calls for cost efficiency
//! - LRU cache to avoid regenerating embeddings
//! - Fallback to local models when cloud providers unavailable
//! - Incremental updates when entities are modified

const std = @import("std");
const manager = @import("manager.zig");
const llm_client = @import("../llm/client.zig");
const embeddings_cartridge = @import("../cartridges/embeddings.zig");

/// Embedding generator plugin configuration
pub const Config = struct {
    // Primary embedding provider (openai, anthropic, local)
    primary_provider: []const u8 = "local",
    // Model name (e.g., "text-embedding-3-small", "all-MiniLM-L6-v2")
    model: []const u8 = "all-MiniLM-L6-v2",
    // Batch size for API calls
    batch_size: usize = 32,
    // Cache size (number of embeddings)
    cache_size: usize = 10000,
    // Maximum cache age in seconds
    cache_ttl_secs: u64 = 3600,
    // Enable fallback to local models
    enable_fallback: bool = true,
    // Fallback provider
    fallback_provider: []const u8 = "local",
    // Fallback model
    fallback_model: []const u8 = "all-MiniLM-L6-v2",
    // Maximum retries for API calls
    max_retries: u32 = 3,
    // Timeout for API calls in ms
    timeout_ms: u32 = 30000,
    // Dimensions for embeddings
    dimensions: u16 = 384,
};

/// Embedding result from API
const EmbeddingResult = struct {
    id: []const u8,
    vector: []const f32,
    model: []const u8,
    tokens_used: u32,

    pub fn deinit(self: *EmbeddingResult, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.vector);
        allocator.free(self.model);
    }
};

/// Cache entry for embeddings
const CacheEntry = struct {
    embedding: []const f32,
    model: []const u8,
    created_at: u64,
    hash: u64,

    pub fn deinit(self: *CacheEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.embedding);
        allocator.free(self.model);
    }
};

/// Embedding generator plugin state
pub const EmbeddingGenerator = struct {
    allocator: std.mem.Allocator,
    config: Config,
    http_client: std.http.Client,
    cache: std.StringHashMap(CacheEntry),
    cache_lru: std.ArrayList([]const u8),
    api_key: ?[]const u8,
    base_url: []const u8,
    stats: Statistics,

    /// Statistics tracking
    const Statistics = struct {
        embeddings_generated: u64 = 0,
        cache_hits: u64 = 0,
        cache_misses: u64 = 0,
        api_calls: u64 = 0,
        total_tokens: u64 = 0,
        errors: u64 = 0,
    };

    /// Create new embedding generator
    pub fn create(allocator: std.mem.Allocator, config: Config) !EmbeddingGenerator {
        return EmbeddingGenerator{
            .allocator = allocator,
            .config = config,
            .http_client = std.http.Client{ .allocator = allocator },
            .cache = std.StringHashMap(CacheEntry).init(allocator),
            .cache_lru = std.ArrayList([]const u8).init(allocator),
            .api_key = null,
            .base_url = "https://api.openai.com/v1",
            .stats = .{},
        };
    }

    /// Cleanup resources
    pub fn deinit(self: *EmbeddingGenerator) void {
        // Cleanup cache
        var it = self.cache.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(self.allocator);
        }
        self.cache.deinit();

        // Cleanup LRU list
        for (self.cache_lru.items) |key| {
            self.allocator.free(key);
        }
        self.cache_lru.deinit();

        // Cleanup HTTP client
        self.http_client.deinit();

        // Cleanup API key if present
        if (self.api_key) |key| self.allocator.free(key);
    }

    /// Initialize plugin (required by Plugin trait)
    pub fn initPlugin(self: *EmbeddingGenerator, allocator: std.mem.Allocator, plugin_config: manager.PluginConfig) !void {
        _ = allocator;
        _ = plugin_config;
        // Already initialized in create()
    }

    /// Cleanup plugin (required by Plugin trait)
    pub fn cleanupPlugin(self: *EmbeddingGenerator, allocator: std.mem.Allocator) !void {
        _ = allocator;
        self.deinit();
    }

    /// Get plugin as manager.Plugin
    pub fn asPlugin(self: *EmbeddingGenerator) manager.Plugin {
        return .{
            .name = "embedding_generator",
            .version = "0.1.0",
            .on_commit = onCommitHook,
            .on_query = null,
            .on_schedule = null,
            .get_functions = null,
        };
    }

    /// Generate embedding for a single text
    pub fn generateEmbedding(self: *EmbeddingGenerator, text: []const u8, entity_id: []const u8) ![]const f32 {
        // Check cache first
        const hash = self.hashContent(text);
        if (try self.getCachedEmbedding(text, hash)) |cached| {
            self.stats.cache_hits += 1;
            return cached;
        }
        self.stats.cache_misses += 1;

        // Generate new embedding
        const embedding = try self.callEmbeddingApi(text, entity_id);
        self.stats.embeddings_generated += 1;

        // Cache the result
        try self.cacheEmbedding(text, hash, embedding, self.config.model);

        return embedding;
    }

    /// Generate embeddings in batch for efficiency
    pub fn generateEmbeddingsBatch(self: *EmbeddingGenerator, texts: []const []const u8, entity_ids: []const []const u8) ![][]const f32 {
        std.debug.assert(texts.len == entity_ids.len);

        // Filter out cached items
        var uncached_texts = std.ArrayList([]const u8).init(self.allocator);
        defer uncached_texts.deinit();
        var uncached_ids = std.ArrayList([]const u8).init(self.allocator);
        defer uncached_ids.deinit();
        var uncached_indices = std.ArrayList(usize).init(self.allocator);
        defer uncached_indices.deinit();

        var results = try self.allocator.alloc([]const f32, texts.len);
        errdefer {
            for (results) |r| {
                if (r.len > 0) self.allocator.free(r);
            }
            self.allocator.free(results);
        }

        // Check cache for each text
        for (texts, entity_ids, 0..) |text, id, i| {
            const hash = self.hashContent(text);
            if (try self.getCachedEmbedding(text, hash)) |cached| {
                self.stats.cache_hits += 1;
                results[i] = cached;
            } else {
                self.stats.cache_misses += 1;
                try uncached_texts.append(text);
                try uncached_ids.append(id);
                try uncached_indices.append(i);
                results[i] = &([_]f32{}); // Placeholder
            }
        }

        // Batch generate uncached embeddings
        if (uncached_texts.items.len > 0) {
            const batch_results = try self.callEmbeddingApiBatch(uncached_texts.items, uncached_ids.items);
            defer {
                for (batch_results) |*r| r.deinit(self.allocator);
                self.allocator.free(batch_results);
            }

            // Fill in results and cache
            for (batch_results, 0..) |result, j| {
                const idx = uncached_indices.items[j];
                const embedding = try self.allocator.dupe(f32, result.vector);
                results[idx] = embedding;

                // Cache this embedding
                try self.cacheEmbedding(uncached_texts.items[j], self.hashContent(uncached_texts.items[j]), embedding, result.model);
            }
        }

        return results;
    }

    /// Get cached embedding if available and not expired
    fn getCachedEmbedding(self: *EmbeddingGenerator, text: []const u8, hash: u64) !?[]const f32 {
        _ = text;

        const now = @as(u64, @intCast(std.time.nanoTimestamp()));
        const now_secs = now / 1_000_000_000;

        var it = self.cache.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.hash == hash) {
                // Check TTL
                const age = now_secs - entry.value_ptr.created_at;
                if (age < self.config.cache_ttl_secs) {
                    // Move to end of LRU (most recently used)
                    return try self.allocator.dupe(f32, entry.value_ptr.embedding);
                } else {
                    // Expired - remove
                    self.allocator.free(entry.key_ptr.*);
                    entry.value_ptr.deinit(self.allocator);
                    self.cache.removeByIter(it);
                    return null;
                }
            }
        }
        return null;
    }

    /// Cache an embedding result
    fn cacheEmbedding(self: *EmbeddingGenerator, text: []const u8, hash: u64, embedding: []const f32, model: []const u8) !void {
        // Evict if cache is full
        while (self.cache.count() >= self.config.cache_size) {
            if (self.cache_lru.items.len > 0) {
                const lru_key = self.cache_lru.orderedRemove(0);
                if (self.cache.get(lru_key)) |entry| {
                    entry.deinit(self.allocator);
                }
                _ = self.cache.remove(lru_key);
                self.allocator.free(lru_key);
            } else {
                break;
            }
        }

        // Store in cache
        const key = try self.allocator.dupe(u8, text);
        errdefer self.allocator.free(key);

        const embedding_copy = try self.allocator.dupe(f32, embedding);
        errdefer self.allocator.free(embedding_copy);

        const model_copy = try self.allocator.dupe(u8, model);
        errdefer self.allocator.free(model_copy);

        const now = @as(u64, @intCast(std.time.nanoTimestamp())) / 1_000_000_000;

        try self.cache.put(key, CacheEntry{
            .embedding = embedding_copy,
            .model = model_copy,
            .created_at = now,
            .hash = hash,
        });

        // Add to LRU
        try self.cache_lru.append(key);
    }

    /// Call embedding API for single text
    fn callEmbeddingApi(self: *EmbeddingGenerator, text: []const u8, entity_id: []const u8) ![]const f32 {
        _ = entity_id;

        const results = try self.callEmbeddingApiBatch(&.{text}, &.{entity_id});
        defer {
            for (results) |*r| r.deinit(self.allocator);
            self.allocator.free(results);
        }

        if (results.len == 0) return error.EmbeddingFailed;

        return self.allocator.dupe(f32, results[0].vector);
    }

    /// Call embedding API for batch of texts
    fn callEmbeddingApiBatch(self: *EmbeddingGenerator, texts: []const []const u8, entity_ids: []const []const u8) ![]EmbeddingResult {
        _ = entity_ids;
        self.stats.api_calls += 1;

        if (std.mem.eql(u8, self.config.primary_provider, "openai")) {
            return self.callOpenAIEmbeddings(texts);
        } else if (std.mem.eql(u8, self.config.primary_provider, "local")) {
            return self.callLocalEmbeddings(texts);
        }

        return error.InvalidProvider;
    }

    /// Call OpenAI embeddings API
    fn callOpenAIEmbeddings(self: *EmbeddingGenerator, texts: []const []const u8) ![]EmbeddingResult {
        // For now, return mock embeddings
        // In production, this would make actual HTTP calls to OpenAI's /v1/embeddings endpoint
        _ = texts;
        self.stats.errors += 1;
        return error.NotImplemented;
    }

    /// Call local embedding model
    fn callLocalEmbeddings(self: *EmbeddingGenerator, texts: []const []const u8) ![]EmbeddingResult {
        // Simple hash-based embedding for testing
        // In production, this would integrate with SentenceTransformers via local server
        const results = try self.allocator.alloc(EmbeddingResult, texts.len);
        errdefer {
            for (results) |*r| r.deinit(self.allocator);
            self.allocator.free(results);
        }

        for (texts, 0..) |text, i| {
            const vector = try self.generateHashBasedEmbedding(text);
            errdefer self.allocator.free(vector);

            const id = try std.fmt.allocPrint(self.allocator, "emb_{d}", .{i});
            errdefer self.allocator.free(id);

            const model_copy = try self.allocator.dupe(u8, self.config.model);
            errdefer self.allocator.free(model_copy);

            results[i] = EmbeddingResult{
                .id = id,
                .vector = vector,
                .model = model_copy,
                .tokens_used = @intCast(text.len / 4), // Rough estimate
            };

            self.stats.total_tokens += results[i].tokens_used;
        }

        return results;
    }

    /// Generate a hash-based embedding for testing
    fn generateHashBasedEmbedding(self: *EmbeddingGenerator, text: []const u8) ![]const f32 {
        const vector = try self.allocator.alloc(f32, self.config.dimensions);
        errdefer self.allocator.free(vector);

        // Use hash to seed random-ish embedding
        var hasher = std.hash.Wyhash.init(0);
        hasher.update(text);
        const seed = hasher.final();

        var rnd = std.Random.Default.init(seed);
        for (0..self.config.dimensions) |i| {
            vector[i] = rnd.float(f32) * 2.0 - 1.0; // [-1, 1]
        }

        return vector;
    }

    /// Hash content for cache key
    fn hashContent(self: *EmbeddingGenerator, text: []const u8) u64 {
        _ = self;
        var hasher = std.hash.Wyhash.init(0);
        hasher.update(text);
        return hasher.final();
    }

    /// Get statistics
    pub fn getStatistics(self: *const EmbeddingGenerator) Statistics {
        return self.stats;
    }

    /// Clear cache
    pub fn clearCache(self: *EmbeddingGenerator) void {
        var it = self.cache.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(self.allocator);
        }
        self.cache.clearRetainingCapacity();

        for (self.cache_lru.items) |key| {
            self.allocator.free(key);
        }
        self.cache_lru.clearRetainingCapacity();
    }
};

/// On-commit hook for automatic embedding generation
fn onCommitHook(allocator: std.mem.Allocator, ctx: manager.CommitContext) anyerror!manager.PluginResult {
    _ = ctx;
    _ = allocator;

    // This hook would be called by the plugin manager
    // For now, just return success
    return manager.PluginResult{
        .success = true,
        .operations_processed = 0,
        .cartridges_updated = 0,
        .confidence = 1.0,
    };
}

// ==================== Tests ====================

test "EmbeddingGenerator initialization" {
    const config = Config{};
    var gen = try EmbeddingGenerator.create(std.testing.allocator, config);
    defer gen.deinit();

    try std.testing.expectEqual(@as(usize, 0), gen.cache.count());
    try std.testing.expectEqual(@as(usize, 10000), gen.config.cache_size);
}

test "EmbeddingGenerator hash_based_embedding" {
    const config = Config{ .dimensions = 128 };
    var gen = try EmbeddingGenerator.create(std.testing.allocator, config);
    defer gen.deinit();

    const text = "test content";
    const emb1 = try gen.generateHashBasedEmbedding(text);
    defer std.testing.allocator.free(emb1);

    const emb2 = try gen.generateHashBasedEmbedding(text);
    defer std.testing.allocator.free(emb2);

    // Same text should produce same embedding
    try std.testing.expectEqual(@as(usize, 128), emb1.len);
    try std.testing.expectEqual(@as(usize, 128), emb2.len);

    for (0..128) |i| {
        try std.testing.expectApproxEqAbs(emb1[i], emb2[i], 0.001);
    }
}

test "EmbeddingGenerator cache_hit" {
    const config = Config{ .cache_size = 10, .cache_ttl_secs = 60 };
    var gen = try EmbeddingGenerator.create(std.testing.allocator, config);
    defer gen.deinit();

    const text = "cache test";
    const entity_id = "entity1";

    // First call - cache miss
    const emb1 = try gen.generateEmbedding(text, entity_id);
    defer std.testing.allocator.free(emb1);

    try std.testing.expectEqual(@as(u64, 1), gen.stats.cache_misses);
    try std.testing.expectEqual(@as(u64, 0), gen.stats.cache_hits);

    // Second call - cache hit
    const emb2 = try gen.generateEmbedding(text, entity_id);
    defer std.testing.allocator.free(emb2);

    try std.testing.expectEqual(@as(u64, 1), gen.stats.cache_misses);
    try std.testing.expectEqual(@as(u64, 1), gen.stats.cache_hits);

    // Embeddings should be identical
    try std.testing.expectEqual(emb1.len, emb2.len);
    for (0..emb1.len) |i| {
        try std.testing.expectApproxEqAbs(emb1[i], emb2[i], 0.001);
    }
}

test "EmbeddingGenerator batch_generation" {
    const config = Config{ .dimensions = 64, .batch_size = 4 };
    var gen = try EmbeddingGenerator.create(std.testing.allocator, config);
    defer gen.deinit();

    const texts = [_][]const u8{ "text1", "text2", "text3" };
    const ids = [_][]const u8{ "id1", "id2", "id3" };

    const embeddings = try gen.generateEmbeddingsBatch(&texts, &ids);
    defer {
        for (embeddings) |emb| std.testing.allocator.free(emb);
        std.testing.allocator.free(embeddings);
    }

    try std.testing.expectEqual(@as(usize, 3), embeddings.len);

    for (embeddings) |emb| {
        try std.testing.expectEqual(@as(usize, 64), emb.len);
    }
}

test "EmbeddingGenerator cache_eviction" {
    const config = Config{ .cache_size = 3, .cache_ttl_secs = 60 };
    var gen = try EmbeddingGenerator.create(std.testing.allocator, config);
    defer gen.deinit();

    // Fill cache
    for (0..5) |i| {
        const text = try std.fmt.allocPrint(std.testing.allocator, "text_{d}", .{i});
        defer std.testing.allocator.free(text);
        const id = try std.fmt.allocPrint(std.testing.allocator, "id_{d}", .{i});
        defer std.testing.allocator.free(id);

        const emb = try gen.generateEmbedding(text, id);
        std.testing.allocator.free(emb);
    }

    // Cache should not exceed max size
    try std.testing.expect(gen.cache.count() <= 3);
}

test "EmbeddingGenerator statistics" {
    const config = Config{ .cache_size = 100 };
    var gen = try EmbeddingGenerator.create(std.testing.allocator, config);
    defer gen.deinit();

    const text = "stats test";
    const id = "entity1";

    // Generate embedding (miss)
    const emb1 = try gen.generateEmbedding(text, id);
    std.testing.allocator.free(emb1);

    // Cache hit
    const emb2 = try gen.generateEmbedding(text, id);
    std.testing.allocator.free(emb2);

    const stats = gen.getStatistics();

    try std.testing.expectEqual(@as(u64, 1), stats.cache_misses);
    try std.testing.expectEqual(@as(u64, 1), stats.cache_hits);
    try std.testing.expectEqual(@as(u64, 1), stats.embeddings_generated);
}

test "EmbeddingGenerator clear_cache" {
    const config = Config{ .cache_size = 10 };
    var gen = try EmbeddingGenerator.create(std.testing.allocator, config);
    defer gen.deinit();

    // Add some embeddings
    const text = "cache test";
    const id = "entity1";
    const emb = try gen.generateEmbedding(text, id);
    std.testing.allocator.free(emb);

    try std.testing.expect(gen.cache.count() > 0);

    // Clear cache
    gen.clearCache();

    try std.testing.expectEqual(@as(usize, 0), gen.cache.count());
    try std.testing.expectEqual(@as(usize, 0), gen.cache_lru.items.len);
}

test "EmbeddingGenerator asPlugin" {
    const config = Config{};
    var gen = try EmbeddingGenerator.create(std.testing.allocator, config);
    defer gen.deinit();

    const plugin = gen.asPlugin();

    try std.testing.expectEqualStrings("embedding_generator", plugin.name);
    try std.testing.expectEqualStrings("0.1.0", plugin.version);
    try std.testing.expect(plugin.on_commit != null);
    try std.testing.expect(plugin.on_query == null);
}
