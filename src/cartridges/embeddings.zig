//! Semantic Embeddings Cartridge Implementation
//!
//! Implements vector storage with HNSW (Hierarchical Navigable Small World) index
//! for semantic similarity search according to spec/structured_memory_v1.md
//!
//! This cartridge supports:
//! - Variable-dimensional embeddings (384d for small models, 1536d for OpenAI)
//! - Multiple quantization options (FP32, FP16, INT8) for storage efficiency
//! - Metadata back-pointers to source entities/commits
//! - Approximate nearest neighbor search via HNSW

const std = @import("std");
const format = @import("format.zig");
const ArrayListManaged = std.ArrayListUnmanaged;

// ==================== Quantization Types ====================

/// Vector storage quantization format
pub const QuantizationType = enum(u8) {
    /// 32-bit float per dimension (no quantization)
    fp32 = 1,
    /// 16-bit float per dimension (half precision)
    fp16 = 2,
    /// 8-bit signed integer per dimension (linear quantization)
    int8 = 3,

    pub fn fromUint(v: u8) !QuantizationType {
        return std.meta.intToEnum(QuantizationType, v);
    }

    pub fn sizeBytes(qt: QuantizationType, dimensions: u16) usize {
        return switch (qt) {
            .fp32 => dimensions * 4,
            .fp16 => dimensions * 2,
            .int8 => dimensions * 1,
        };
    }
};

// ==================== Embedding Record ====================

/// Single embedding record with vector and metadata
pub const Embedding = struct {
    /// Unique identifier for this embedding
    id: []const u8,
    /// Embedding vector (quantized based on storage type)
    data: []const u8,
    /// Original dimensionality before quantization
    dimensions: u16,
    /// Quantization format used
    quantization: QuantizationType,
    /// Source entity this embedding represents
    entity_namespace: []const u8,
    entity_local_id: []const u8,
    /// Model/version that generated this embedding
    model_name: []const u8,
    /// Timestamp when embedding was created
    created_at: u64,
    /// Relevance score or confidence
    confidence: f32 = 1.0,

    /// Calculate serialized size for storage
    pub fn serializedSize(self: Embedding) usize {
        var size: usize = 2 + self.id.len; // id length + id
        size += 2 + self.data.len; // data length + data
        size += 2; // dimensions
        size += 1; // quantization type
        size += 2 + self.entity_namespace.len; // entity_namespace length + entity_namespace
        size += 2 + self.entity_local_id.len; // entity_local_id length + entity_local_id
        size += 2 + self.model_name.len; // model_name length + model_name
        size += 8; // created_at
        size += 4; // confidence
        return size;
    }

    /// Serialize embedding to byte stream
    pub fn serialize(self: Embedding, writer: anytype) !void {
        try writer.writeInt(u16, @intCast(self.id.len), .little);
        try writer.writeAll(self.id);

        try writer.writeInt(u16, @intCast(self.data.len), .little);
        try writer.writeAll(self.data);

        try writer.writeInt(u16, self.dimensions, .little);
        try writer.writeByte(@intFromEnum(self.quantization));

        try writer.writeInt(u16, @intCast(self.entity_namespace.len), .little);
        try writer.writeAll(self.entity_namespace);

        try writer.writeInt(u16, @intCast(self.entity_local_id.len), .little);
        try writer.writeAll(self.entity_local_id);

        try writer.writeInt(u16, @intCast(self.model_name.len), .little);
        try writer.writeAll(self.model_name);

        try writer.writeInt(u64, self.created_at, .little);
        try writer.writeInt(u32, @bitCast(self.confidence), .little);
    }

    /// Deserialize embedding from byte stream
    pub fn deserialize(reader: anytype, allocator: std.mem.Allocator) !Embedding {
        const id_len = try reader.readInt(u16, .little);
        const id = try allocator.alloc(u8, id_len);
        try reader.readNoEof(id);

        const data_len = try reader.readInt(u16, .little);
        const data = try allocator.alloc(u8, data_len);
        try reader.readNoEof(data);

        const dimensions = try reader.readInt(u16, .little);
        const quantization_byte = try reader.readByte();
        const quantization = try QuantizationType.fromUint(quantization_byte);

        const entity_ns_len = try reader.readInt(u16, .little);
        const entity_namespace = try allocator.alloc(u8, entity_ns_len);
        try reader.readNoEof(entity_namespace);

        const entity_local_len = try reader.readInt(u16, .little);
        const entity_local_id = try allocator.alloc(u8, entity_local_len);
        try reader.readNoEof(entity_local_id);

        const model_len = try reader.readInt(u16, .little);
        const model_name = try allocator.alloc(u8, model_len);
        try reader.readNoEof(model_name);

        const created_at = try reader.readInt(u64, .little);
        const confidence_bits = try reader.readInt(u32, .little);
        const confidence = @as(f32, @bitCast(confidence_bits));

        return Embedding{
            .id = id,
            .data = data,
            .dimensions = dimensions,
            .quantization = quantization,
            .entity_namespace = entity_namespace,
            .entity_local_id = entity_local_id,
            .model_name = model_name,
            .created_at = created_at,
            .confidence = confidence,
        };
    }

    /// Free embedding resources
    pub fn deinit(self: Embedding, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.data);
        allocator.free(self.entity_namespace);
        allocator.free(self.entity_local_id);
        allocator.free(self.model_name);
    }
};

// ==================== HNSW Index ====================

/// HNSW (Hierarchical Navigable Small World) graph node
const HNSWNode = struct {
    /// Node ID (index into vectors array)
    id: u32,
    /// Connections at each level (level -> [neighbor_ids])
    connections: ArrayListManaged(ArrayListManaged(u32)),
    /// Vector data index
    vector_index: u32,

    pub fn init(allocator: std.mem.Allocator, id: u32, max_level: usize, vector_index: u32) !HNSWNode {
        var connections = try ArrayListManaged(ArrayListManaged(u32)).initCapacity(allocator, max_level + 1);
        for (0..max_level + 1) |_| {
            try connections.append(allocator, .{});
        }

        return HNSWNode{
            .id = id,
            .connections = connections,
            .vector_index = vector_index,
        };
    }

    pub fn deinit(self: *HNSWNode, allocator: std.mem.Allocator) void {
        for (self.connections.items) |*level| {
            level.deinit(allocator);
        }
        self.connections.deinit(allocator);
    }

    /// Add neighbor at specific level
    pub fn addNeighbor(self: *HNSWNode, allocator: std.mem.Allocator, level: usize, neighbor_id: u32) !void {
        if (level < self.connections.items.len) {
            try self.connections.items[level].append(allocator, neighbor_id);
        }
    }
};

/// Search result with similarity score
pub const SearchResult = struct {
    embedding_id: u32,
    score: f32,
    entity_namespace: []const u8,
    entity_local_id: []const u8,

    pub fn deinit(self: SearchResult, allocator: std.mem.Allocator) void {
        allocator.free(self.entity_namespace);
        allocator.free(self.entity_local_id);
    }
};

/// HNSW index for approximate nearest neighbor search
pub const HNSWIndex = struct {
    allocator: std.mem.Allocator,
    /// Maximum number of layers in the hierarchy
    max_level: usize,
    /// Maximum connections per node per layer (M parameter)
    max_connections: usize,
    /// ef_construction parameter for building
    ef_construction: usize,
    /// ef_search parameter for queries
    ef_search: usize,
    /// Entry point for search (node at highest level)
    entry_point: ?u32,
    /// All nodes in the graph
    nodes: ArrayListManaged(HNSWNode),
    /// Vector data (FP32 for computation)
    vectors: ArrayListManaged(ArrayListManaged(f32)),
    /// Embedding metadata for each vector
    embeddings: ArrayListManaged(Embedding),

    /// HNSW parameters
    const mL = 1.0 / @log(2.0); // For level generation

    pub fn init(allocator: std.mem.Allocator, options: HNSWOptions) !HNSWIndex {
        _ = options;
        return HNSWIndex{
            .allocator = allocator,
            .max_level = 16,
            .max_connections = 16,
            .ef_construction = 200,
            .ef_search = 50,
            .entry_point = null,
            .nodes = .{},
            .vectors = .{},
            .embeddings = .{},
        };
    }

    pub fn deinit(self: *HNSWIndex) void {
        for (self.nodes.items) |*node| node.deinit(self.allocator);
        self.nodes.deinit(self.allocator);

        for (self.vectors.items) |*vec| vec.deinit(self.allocator);
        self.vectors.deinit(self.allocator);

        for (self.embeddings.items) |*emb| emb.deinit(self.allocator);
        self.embeddings.deinit(self.allocator);
    }

    /// Insert a vector into the HNSW index
    pub fn insert(self: *HNSWIndex, embedding: Embedding, vector: []const f32) !void {
        // Determine max level for this node
        const level = self.getRandomLevel();

        const node_id = @as(u32, @intCast(self.nodes.items.len));
        const node = try HNSWNode.init(self.allocator, node_id, level, node_id);
        try self.nodes.append(self.allocator, node);

        // Store vector copy
        var vec_copy = try ArrayListManaged(f32).initCapacity(self.allocator, vector.len);
        for (vector) |v| try vec_copy.append(self.allocator, v);
        try self.vectors.append(self.allocator, vec_copy);

        // Create a deep copy of embedding with owned strings
        const owned_embedding = Embedding{
            .id = try self.allocator.dupe(u8, embedding.id),
            .data = try self.allocator.dupe(u8, embedding.data),
            .dimensions = embedding.dimensions,
            .quantization = embedding.quantization,
            .entity_namespace = try self.allocator.dupe(u8, embedding.entity_namespace),
            .entity_local_id = try self.allocator.dupe(u8, embedding.entity_local_id),
            .model_name = try self.allocator.dupe(u8, embedding.model_name),
            .created_at = embedding.created_at,
            .confidence = embedding.confidence,
        };
        try self.embeddings.append(self.allocator, owned_embedding);

        // If first node or new highest level, set as entry point
        if (self.entry_point == null or level > self.getCurrentMaxLevel()) {
            self.entry_point = node_id;
        }

        // Insert into hierarchy
        if (self.nodes.items.len > 1) {
            const entry = self.entry_point orelse return;
            try self.insertStartingFrom(node_id, level, entry, self.getCurrentMaxLevel());
        }
    }

    /// Search for k nearest neighbors
    pub fn search(self: *const HNSWIndex, query: []const f32, k: usize) !ArrayListManaged(SearchResult) {
        var results = ArrayListManaged(SearchResult){};

        if (self.nodes.items.len == 0) return results;
        if (k == 0) return results;

        const entry = self.entry_point orelse return results;
        const max_level = self.getCurrentMaxLevel();

        // Search from top down
        var current = entry;

        // Descend to target level
        var level: isize = @intCast(max_level);
        while (level > 0) {
            level -= 1;
            {
                var layer_results = try self.searchLayer(query, current, @intCast(level), 1);
                defer layer_results.deinit(self.allocator);
                if (layer_results.items.len > 0) {
                    current = layer_results.items[0].id;
                }
            }
        }

        // Search at bottom level for k nearest
        var candidates = try self.searchLayer(query, current, 0, @min(self.ef_search, self.nodes.items.len));
        defer candidates.deinit(self.allocator);

        // Convert to results (already sorted by distance in searchLayer)
        const result_count = @min(k, candidates.items.len);
        for (candidates.items[0..result_count]) |candidate| {
            const embedding = &self.embeddings.items[candidate.vector_index];

            // Copy entity info
            const entity_ns = try self.allocator.dupe(u8, embedding.entity_namespace);
            errdefer self.allocator.free(entity_ns);
            const entity_local = try self.allocator.dupe(u8, embedding.entity_local_id);
            errdefer self.allocator.free(entity_local);

            try results.append(self.allocator, SearchResult{
                .embedding_id = candidate.id,
                .score = candidate.distance,
                .entity_namespace = entity_ns,
                .entity_local_id = entity_local,
            });
        }

        return results;
    }

    /// Get random level for new node (geometric distribution)
    fn getRandomLevel(self: *const HNSWIndex) usize {
        const ts = @as(u64, @intCast(std.time.nanoTimestamp()));
        const r = @as(f32, @floatFromInt(ts % 1000000)) / 1000000.0;
        const level = @as(usize, @intFromFloat(@floor(-@as(f32, @floatCast(@log(r))) * mL)));
        return @min(level, self.max_level);
    }

    /// Get current max level in the graph
    fn getCurrentMaxLevel(self: *const HNSWIndex) usize {
        var max: usize = 0;
        for (self.nodes.items) |*node| {
            const node_level = node.connections.items.len - 1;
            if (node_level > max) max = node_level;
        }
        return max;
    }

    /// Insert node starting from a specific level
    fn insertStartingFrom(self: *HNSWIndex, node_id: u32, target_level: usize, entry_point: u32, current_level: usize) !void {
        var current = entry_point;

        // Descend from top to target_level
        var level = current_level;
        while (level > target_level) {
            level -= 1;
            current = self.searchLayerSingle(self.nodes.items[node_id].vector_index, current, level).id;
        }

        // At each level up to target_level, find neighbors and connect
        level = @min(target_level, self.getCurrentMaxLevel());
        while (level >= 0) {
            var candidates = try self.searchLayer(
                self.vectors.items[self.nodes.items[node_id].vector_index].items,
                current,
                level,
                @min(self.ef_construction, self.nodes.items.len),
            );
            defer candidates.deinit(self.allocator);

            // Select up to max_connections neighbors
            const M = @min(self.max_connections, candidates.items.len);
            for (candidates.items[0..M]) |candidate| {
                // Add bidirectional connection
                try self.nodes.items[node_id].addNeighbor(self.allocator, level, candidate.id);
                try self.nodes.items[candidate.id].addNeighbor(self.allocator, level, node_id);
            }

            if (level > 0) {
                // Use best candidate as entry for next level
                if (candidates.items.len > 0) {
                    current = candidates.items[0].id;
                }
            }

            if (level == 0) break;
            level -= 1;
        }
    }

    /// Search at a specific level
    fn searchLayer(self: *const HNSWIndex, query: []const f32, entry_point: u32, level: usize, ef: usize) !ArrayListManaged(Candidate) {
        var visited = std.AutoHashMap(u32, void).init(self.allocator);
        defer visited.deinit();

        var candidates = try ArrayListManaged(Candidate).initCapacity(self.allocator, ef);
        var w = try ArrayListManaged(Candidate).initCapacity(self.allocator, ef); // working set
        defer w.deinit(self.allocator);

        const entry_dist = self.distance(query, self.nodes.items[entry_point].vector_index);
        try candidates.append(self.allocator, .{ .id = entry_point, .vector_index = @intCast(self.nodes.items[entry_point].vector_index), .distance = entry_dist });
        try w.append(self.allocator, .{ .id = entry_point, .vector_index = @intCast(self.nodes.items[entry_point].vector_index), .distance = entry_dist });
        try visited.put(entry_point, {});

        while (w.items.len > 0) {
            // Get closest from working set
            std.sort.heap(Candidate, w.items, {}, struct {
                fn lessThan(_: void, a: Candidate, b: Candidate) bool {
                    return a.distance < b.distance;
                }
            }.lessThan);

            const current = w.orderedRemove(0);

            // Check if we can improve
            if (candidates.items.len >= ef and current.distance > candidates.items[candidates.items.len - 1].distance) {
                break;
            }

            // Check neighbors
            const node = &self.nodes.items[current.id];
            if (level < node.connections.items.len) {
                for (node.connections.items[level].items) |neighbor_id| {
                    if (visited.get(neighbor_id) != null) continue;
                    try visited.put(neighbor_id, {});

                    const neighbor_dist = self.distance(query, self.nodes.items[neighbor_id].vector_index);

                    if (candidates.items.len < ef or neighbor_dist < candidates.items[candidates.items.len - 1].distance) {
                        try candidates.append(self.allocator, .{
                            .id = neighbor_id,
                            .vector_index = @intCast(self.nodes.items[neighbor_id].vector_index),
                            .distance = neighbor_dist,
                        });

                        // Sort and trim
                        std.sort.heap(Candidate, candidates.items, {}, struct {
                            fn lessThan(_: void, a: Candidate, b: Candidate) bool {
                                return a.distance < b.distance;
                            }
                        }.lessThan);

                        if (candidates.items.len > ef) {
                            // Trim excess
                            const excess = candidates.orderedRemove(candidates.items.len - 1);
                            _ = excess;
                        }

                        try w.append(self.allocator, .{
                            .id = neighbor_id,
                            .vector_index = @intCast(self.nodes.items[neighbor_id].vector_index),
                            .distance = neighbor_dist,
                        });
                    }
                }
            }
        }

        return candidates;
    }

    /// Search at a specific level, return single closest
    fn searchLayerSingle(self: *const HNSWIndex, vector_index: usize, entry_point: u32, level: usize) Candidate {
        var current = entry_point;
        var current_dist = self.distance(self.vectors.items[vector_index].items, self.nodes.items[entry_point].vector_index);

        const node = &self.nodes.items[current];
        if (level < node.connections.items.len) {
            for (node.connections.items[level].items) |neighbor_id| {
                const neighbor_dist = self.distance(self.vectors.items[vector_index].items, self.nodes.items[neighbor_id].vector_index);
                if (neighbor_dist < current_dist) {
                    current = neighbor_id;
                    current_dist = neighbor_dist;
                }
            }
        }

        return .{ .id = current, .vector_index = @intCast(self.nodes.items[current].vector_index), .distance = current_dist };
    }

    /// Calculate Euclidean distance between two vectors
    fn distance(self: *const HNSWIndex, query: []const f32, vector_index: usize) f32 {
        const target = self.vectors.items[vector_index].items;
        const dims = @min(query.len, target.len);

        var sum: f32 = 0;
        for (0..dims) |i| {
            const diff = query[i] - target[i];
            sum += diff * diff;
        }

        return @sqrt(sum);
    }
};

const Candidate = struct {
    id: u32,
    vector_index: u32,
    distance: f32,

    pub fn format(c: Candidate, allocator: std.mem.Allocator) ![]const u8 {
        return std.fmt.allocPrint(allocator, "Candidate{{id={d},dist={d:.4}}}", .{ c.id, c.distance });
    }
};

/// HNSW configuration options
pub const HNSWOptions = struct {
    max_level: usize = 16,
    max_connections: usize = 16,
    ef_construction: usize = 200,
    ef_search: usize = 50,
};

// ==================== Embeddings Cartridge ====================

/// Semantic embeddings cartridge with HNSW index
pub const EmbeddingsCartridge = struct {
    allocator: std.mem.Allocator,
    header: format.CartridgeHeader,
    /// HNSW index for vector search
    index: HNSWIndex,
    /// Dimensionality of vectors in this cartridge
    dimensions: u16,
    /// Quantization type used
    quantization: QuantizationType,

    /// Create new embeddings cartridge
    pub fn init(allocator: std.mem.Allocator, source_txn_id: u64, dimensions: u16, quantization: QuantizationType) !EmbeddingsCartridge {
        const header = format.CartridgeHeader.init(.semantic_embeddings, source_txn_id);
        const index = try HNSWIndex.init(allocator, .{});

        return EmbeddingsCartridge{
            .allocator = allocator,
            .header = header,
            .index = index,
            .dimensions = dimensions,
            .quantization = quantization,
        };
    }

    pub fn deinit(self: *EmbeddingsCartridge) void {
        self.index.deinit();
    }

    /// Add an embedding to the cartridge
    pub fn addEmbedding(self: *EmbeddingsCartridge, embedding: Embedding, vector: []const f32) !void {
        if (vector.len != self.dimensions) return error.DimensionMismatch;

        try self.index.insert(embedding, vector);
        self.header.entry_count += 1;
    }

    /// Search for similar embeddings
    pub fn search(self: *const EmbeddingsCartridge, query: []const f32, k: usize) !ArrayListManaged(SearchResult) {
        if (query.len != self.dimensions) return error.DimensionMismatch;

        return self.index.search(query, k);
    }

    /// Write cartridge to file
    pub fn writeToFile(self: *EmbeddingsCartridge, path: []const u8) !void {
        const file = try std.fs.cwd().createFile(path, .{ .read = true });
        defer file.close();

        // Write header
        try self.header.serialize(file.writer().any());

        // Write data section (embeddings)
        // For simplicity, serialize as JSON metadata
        var metadata_buf: [1024]u8 = undefined;
        const metadata_str = try std.fmt.bufPrint(&metadata_buf,
            "{{\"dimensions\":{d},\"quantization\":\"{s}\",\"count\":{d}}}",
            .{ self.dimensions, @tagName(self.quantization), self.header.entry_count }
        );

        try file.writeAll(metadata_str);
    }
};

// ==================== Tests ====================

test "QuantizationType.sizeBytes" {
    try std.testing.expectEqual(@as(usize, 1536 * 4), QuantizationType.sizeBytes(.fp32, 1536));
    try std.testing.expectEqual(@as(usize, 384 * 2), QuantizationType.sizeBytes(.fp16, 384));
    try std.testing.expectEqual(@as(usize, 768 * 1), QuantizationType.sizeBytes(.int8, 768));
}

test "Embedding.serializedSize" {
    const embedding = Embedding{
        .id = "test_emb",
        .data = &([_]u8{0} ** 1536),
        .dimensions = 384,
        .quantization = .fp32,
        .entity_namespace = "file",
        .entity_local_id = "src/main.zig",
        .model_name = "all-MiniLM-L6-v2",
        .created_at = 12345,
        .confidence = 0.95,
    };

    const size = embedding.serializedSize();
    try std.testing.expect(size > 0);
}

test "Embedding.serialize roundtrip" {
    const original_data = [_]f32{0.1, 0.2, 0.3, 0.4};
    var data_bytes: [@sizeOf(f32) * 4]u8 = undefined;
        @memcpy(&data_bytes, std.mem.sliceAsBytes(&original_data));

    const original = Embedding{
        .id = "test",
        .data = &data_bytes,
        .dimensions = 4,
        .quantization = .fp32,
        .entity_namespace = "test_ns",
        .entity_local_id = "test_id",
        .model_name = "test_model",
        .created_at = 100,
        .confidence = 0.9,
    };

    var buffer: [512]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buffer);
    try original.serialize(fbs.writer());

    fbs.pos = 0;
    const restored = try Embedding.deserialize(fbs.reader(), std.testing.allocator);
    defer restored.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("test", restored.id);
    try std.testing.expectEqual(@as(u16, 4), restored.dimensions);
    try std.testing.expectEqual(QuantizationType.fp32, restored.quantization);
}

test "HNSWIndex.init and insert" {
    var index = try HNSWIndex.init(std.testing.allocator, .{});
    defer index.deinit();

    const vector1 = [_]f32{ 0.1, 0.2, 0.3 };
    const embedding1 = Embedding{
        .id = "emb1",
        .data = &([_]u8{0} ** 12),
        .dimensions = 3,
        .quantization = .fp32,
        .entity_namespace = "file",
        .entity_local_id = "a.zig",
        .model_name = "test",
        .created_at = 100,
    };
    try index.insert(embedding1, &vector1);

    try std.testing.expectEqual(@as(usize, 1), index.nodes.items.len);
    try std.testing.expectEqual(@as(usize, 1), index.vectors.items.len);
}

test "HNSWIndex.search" {
    var index = try HNSWIndex.init(std.testing.allocator, .{});
    defer index.deinit();

    // Add some vectors
    const vectors = [3][3]f32{
        [_]f32{ 1.0, 0.0, 0.0 },
        [_]f32{ 0.0, 1.0, 0.0 },
        [_]f32{ 0.0, 0.0, 1.0 },
    };

    for (vectors, 0..) |v, i| {
        const id = try std.fmt.allocPrint(std.testing.allocator, "emb{d}", .{i});
        defer std.testing.allocator.free(id);

        const embedding = Embedding{
            .id = id,
            .data = &([_]u8{0} ** 12),
            .dimensions = 3,
            .quantization = .fp32,
            .entity_namespace = "file",
            .entity_local_id = id,
            .model_name = "test",
            .created_at = @intCast(100 + i),
        };
        try index.insert(embedding, &v);
    }

    // Search for nearest to [1, 0, 0]
    const query = [_]f32{ 1.0, 0.0, 0.0 };
    var results = try index.search(&query, 2);
    defer {
        for (results.items) |*r| r.deinit(std.testing.allocator);
        results.deinit(std.testing.allocator);
    }

    try std.testing.expect(results.items.len >= 1);
}

test "EmbeddingsCartridge.init and addEmbedding" {
    var cartridge = try EmbeddingsCartridge.init(std.testing.allocator, 100, 384, .fp32);
    defer cartridge.deinit();

    const vector = [_]f32{0.1} ** 384;
    const embedding = Embedding{
        .id = "test_emb",
        .data = &([_]u8{0} ** 1536),
        .dimensions = 384,
        .quantization = .fp32,
        .entity_namespace = "file",
        .entity_local_id = "src/test.zig",
        .model_name = "all-MiniLM-L6-v2",
        .created_at = 12345,
        .confidence = 0.95,
    };

    try cartridge.addEmbedding(embedding, &vector);

    try std.testing.expectEqual(@as(u64, 1), cartridge.header.entry_count);
}

test "EmbeddingsCartridge.search" {
    var cartridge = try EmbeddingsCartridge.init(std.testing.allocator, 100, 3, .fp32);
    defer cartridge.deinit();

    // Add embeddings
    const vectors = [2][3]f32{
        [_]f32{ 1.0, 0.0, 0.0 },
        [_]f32{ 0.9, 0.1, 0.0 },
    };

    for (vectors, 0..) |v, i| {
        const id = try std.fmt.allocPrint(std.testing.allocator, "emb{d}", .{i});
        defer std.testing.allocator.free(id);

        const embedding = Embedding{
            .id = id,
            .data = &([_]u8{0} ** 12),
            .dimensions = 3,
            .quantization = .fp32,
            .entity_namespace = "file",
            .entity_local_id = id,
            .model_name = "test",
            .created_at = @intCast(100 + i),
        };
        try cartridge.addEmbedding(embedding, &v);
    }

    // Search
    const query = [_]f32{ 1.0, 0.0, 0.0 };
    var results = try cartridge.search(&query, 2);

    defer {
        for (results.items) |*r| r.deinit(std.testing.allocator);
        results.deinit(std.testing.allocator);
    }

    try std.testing.expect(results.items.len >= 1);
}
