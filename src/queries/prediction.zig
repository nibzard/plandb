//! Predictive cartridge building based on query patterns
//!
//! Analyzes historical query patterns to predict which cartridges will be
//! needed and proactively builds them before actual queries occur.

const std = @import("std");
const mem = std.mem;

const QueryStatistics = @import("optimizer.zig").QueryStatistics;

/// Prediction engine for proactive cartridge building
pub const PredictionEngine = struct {
    allocator: std.mem.Allocator,
    pattern_history: std.ArrayList(PatternObservation),
    predictions: std.ArrayList(Prediction),
    config: PredictionConfig,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return PredictionEngine{
            .allocator = allocator,
            .pattern_history = std.array_list.Managed(PatternObservation).init(allocator),
            .predictions = std.array_list.Managed(Prediction).init(allocator),
            .config = PredictionConfig.default(),
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.pattern_history.items) |*p| p.deinit(self.allocator);
        self.pattern_history.deinit();

        for (self.predictions.items) |*p| p.deinit(self.allocator);
        self.predictions.deinit();
    }

    /// Record a query pattern observation
    pub fn recordObservation(self: *Self, pattern: []const u8, cartridge_type: CartridgeType, timestamp_ms: u64) !void {
        const observation = PatternObservation{
            .pattern = try self.allocator.dupe(u8, pattern),
            .cartridge_type = cartridge_type,
            .timestamp_ms = timestamp_ms,
            .access_count = 1,
        };

        try self.pattern_history.append(observation);

        // Update existing observation if pattern already seen
        for (self.pattern_history.items) |*obs| {
            if (mem.eql(u8, obs.pattern, pattern) and obs.cartridge_type == cartridge_type) {
                obs.access_count += 1;
                return;
            }
        }
    }

    /// Generate predictions for future cartridge needs
    pub fn generatePredictions(self: *Self) ![]const Prediction {
        // Clear old predictions
        for (self.predictions.items) |*p| p.deinit(self.allocator);
        self.predictions.clearRetainingCapacity();

        const now = @as(u64, @intCast(std.time.nanoTimestamp() / 1_000_000));

        // Analyze patterns and predict future needs
        var pattern_counts = std.StringHashMap(usize).init(self.allocator);
        defer {
            var it = pattern_counts.iterator();
            while (it.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
            }
            pattern_counts.deinit();
        }

        // Count pattern occurrences
        for (self.pattern_history.items) |obs| {
            // Only consider recent observations
            const age_ms = now - obs.timestamp_ms;
            if (age_ms > self.config.prediction_window_ms) continue;

            const entry = try pattern_counts.getOrPut(obs.pattern);
            if (!entry.found_existing) {
                entry.value_ptr.* = 0;
            }
            entry.value_ptr.* += obs.access_count;
        }

        // Generate predictions based on frequency
        var it = pattern_counts.iterator();
        while (it.next()) |entry| {
            const count = entry.value_ptr.*;
            if (count >= self.config.min_prediction_frequency) {
                // Find associated cartridge type
                var cart_type: ?CartridgeType = null;
                for (self.pattern_history.items) |obs| {
                    if (mem.eql(u8, obs.pattern, entry.key_ptr.*)) {
                        cart_type = obs.cartridge_type;
                        break;
                    }
                }

                if (cart_type) |ct| {
                    const confidence = @min(1.0, @as(f32, @floatFromInt(count)) / @as(f32, @floatFromInt(self.config.min_prediction_frequency * 2)));

                    try self.predictions.append(Prediction{
                        .pattern = try self.allocator.dupe(u8, entry.key_ptr.*),
                        .cartridge_type = ct,
                        .confidence = confidence,
                        .predicted_access_count = count,
                        .reasoning = try std.fmt.allocPrint(
                            self.allocator,
                            "Pattern accessed {d} times in window",
                            .{count}
                        ),
                    });
                }
            }
        }

        // Sort by confidence
        std.sort.insertion(Prediction, self.predictions.items, {}, struct {
            fn lessThan(_: void, a: Prediction, b: Prediction) bool {
                return a.confidence > b.confidence;
            }
        }.lessThan);

        return self.predictions.items;
    }

    /// Get cartridges to build proactively
    pub fn getCartridgesToBuild(self: *Self, limit: usize) ![]const BuildAction {
        var actions = std.array_list.Managed(BuildAction).init(self.allocator);

        const predictions = try self.generatePredictions();

        for (predictions[0..@min(predictions.len, limit)]) |pred| {
            if (pred.confidence >= self.config.min_confidence_threshold) {
                try actions.append(BuildAction{
                    .cartridge_type = pred.cartridge_type,
                    .pattern = try self.allocator.dupe(u8, pred.pattern),
                    .priority = pred.confidence,
                    .estimated_benefit = pred.predicted_access_count,
                });
            }
        }

        return actions.toOwnedSlice();
    }

    /// Prune old observations
    pub fn pruneOldObservations(self: *Self) !usize {
        const now = @as(u64, @intCast(std.time.nanoTimestamp() / 1_000_000));
        var removed: usize = 0;

        var i: usize = 0;
        while (i < self.pattern_history.items.len) {
            const age_ms = now - self.pattern_history.items[i].timestamp_ms;
            if (age_ms > self.config.retention_period_ms) {
                self.pattern_history.items[i].deinit(self.allocator);
                _ = self.pattern_history.orderedRemove(i);
                removed += 1;
            } else {
                i += 1;
            }
        }

        return removed;
    }

    /// Get prediction statistics
    pub fn getStats(self: *const Self) PredictionStats {
        var total_observations: u64 = 0;
        var unique_patterns: usize = 0;
        var pattern_set = std.StringHashMap(void).init(self.allocator);
        defer pattern_set.deinit();

        for (self.pattern_history.items) |obs| {
            total_observations += obs.access_count;
            if (!pattern_set.contains(obs.pattern)) {
                pattern_set.put(obs.pattern, {}) catch {};
                unique_patterns += 1;
            }
        }

        return PredictionStats{
            .total_observations = total_observations,
            .unique_patterns = unique_patterns,
            .active_predictions = self.predictions.items.len,
        };
    }
};

/// Pattern observation
pub const PatternObservation = struct {
    pattern: []const u8,
    cartridge_type: CartridgeType,
    timestamp_ms: u64,
    access_count: u64,

    pub fn deinit(self: *PatternObservation, allocator: std.mem.Allocator) void {
        allocator.free(self.pattern);
    }
};

/// Prediction result
pub const Prediction = struct {
    pattern: []const u8,
    cartridge_type: CartridgeType,
    confidence: f32,
    predicted_access_count: usize,
    reasoning: []const u8,

    pub fn deinit(self: *Prediction, allocator: std.mem.Allocator) void {
        allocator.free(self.pattern);
        allocator.free(self.reasoning);
    }
};

/// Build action for proactive cartridge building
pub const BuildAction = struct {
    cartridge_type: CartridgeType,
    pattern: []const u8,
    priority: f32,
    estimated_benefit: usize,

    pub fn deinit(self: *BuildAction, allocator: std.mem.Allocator) void {
        allocator.free(self.pattern);
    }
};

/// Prediction configuration
pub const PredictionConfig = struct {
    /// Minimum frequency to trigger a prediction
    min_prediction_frequency: usize = 5,
    /// Minimum confidence threshold for proactive building
    min_confidence_threshold: f32 = 0.6,
    /// Time window for pattern analysis (milliseconds)
    prediction_window_ms: u64 = 60 * 60 * 1000, // 1 hour
    /// How long to keep observations (milliseconds)
    retention_period_ms: u64 = 24 * 60 * 60 * 1000, // 24 hours

    pub fn default() PredictionConfig {
        return PredictionConfig{};
    }
};

/// Prediction statistics
pub const PredictionStats = struct {
    total_observations: u64,
    unique_patterns: usize,
    active_predictions: usize,
};

/// Cartridge type for predictions
pub const CartridgeType = enum {
    entity_index,
    topic_index,
    relationship_graph,
    pending_tasks_by_type,
};

/// Proactive builder for predicted cartridges
pub const ProactiveBuilder = struct {
    allocator: std.mem.Allocator,
    engine: PredictionEngine,
    build_queue: std.ArrayList(BuildAction),
    stats: BuildStats,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return ProactiveBuilder{
            .allocator = allocator,
            .engine = PredictionEngine.init(allocator),
            .build_queue = std.array_list.Managed(BuildAction).init(allocator),
            .stats = BuildStats{},
        };
    }

    pub fn deinit(self: *Self) void {
        self.engine.deinit();

        for (self.build_queue.items) |*action| {
            action.deinit(self.allocator);
        }
        self.build_queue.deinit();
    }

    /// Update builder with new query observation
    pub fn recordQuery(self: *Self, pattern: []const u8, cartridge_type: CartridgeType) !void {
        const now = @as(u64, @intCast(std.time.nanoTimestamp() / 1_000_000));
        try self.engine.recordObservation(pattern, cartridge_type, now);

        // Periodically prune old observations
        if (self.engine.pattern_history.items.len % 100 == 0) {
            _ = try self.engine.pruneOldObservations();
        }
    }

    /// Generate and queue build actions
    pub fn updateBuildQueue(self: *Self) !usize {
        // Clear old queue
        for (self.build_queue.items) |*action| {
            action.deinit(self.allocator);
        }
        self.build_queue.clearRetainingCapacity();

        // Get new predictions
        const actions = try self.engine.getCartridgesToBuild(self.engine.config.min_prediction_frequency);
        errdefer {
            for (actions) |*action| {
                action.deinit(self.allocator);
            }
            self.allocator.free(actions);
        }

        for (actions) |action| {
            try self.build_queue.append(action);
        }

        return self.build_queue.items.len;
    }

    /// Get next build action
    pub fn getNextBuild(self: *const Self) ?BuildAction {
        if (self.build_queue.items.len == 0) return null;

        // Return highest priority action
        var best_idx: usize = 0;
        var best_priority: f32 = 0;

        for (self.build_queue.items, 0..) |action, i| {
            if (action.priority > best_priority) {
                best_priority = action.priority;
                best_idx = i;
            }
        }

        // Clone the action
        const action = self.build_queue.items[best_idx];
        return BuildAction{
            .cartridge_type = action.cartridge_type,
            .pattern = try self.allocator.dupe(u8, action.pattern),
            .priority = action.priority,
            .estimated_benefit = action.estimated_benefit,
        };
    }

    /// Execute build actions (would integrate with actual cartridge builder)
    pub fn executeBuilds(self: *Self, limit: usize) !BuildResult {
        var built: usize = 0;
        var skipped: usize = 0;

        var i: usize = 0;
        while (i < self.build_queue.items.len and built < limit) : (i += 1) {
            _ = self.build_queue.items[i];

            // Check if already exists (simplified)
            const should_build = true;

            if (should_build) {
                // In real implementation, would build cartridge here
                built += 1;
            } else {
                skipped += 1;
            }
        }

        self.stats.total_builds += built;
        self.stats.total_skipped += skipped;

        return BuildResult{
            .built = built,
            .skipped = skipped,
            .remaining = self.build_queue.items.len - built - skipped,
        };
    }

    /// Get builder statistics
    pub fn getStats(self: *const Self) BuildStats {
        return self.stats;
    }
};

/// Build execution result
pub const BuildResult = struct {
    built: usize,
    skipped: usize,
    remaining: usize,
};

/// Build statistics
pub const BuildStats = struct {
    total_builds: u64 = 0,
    total_skipped: u64 = 0,
};

/// Time-based prediction for periodic access patterns
pub const TimeBasedPredictor = struct {
    allocator: std.mem.Allocator,
    hourly_patterns: [24]std.ArrayList(PatternObservation),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        var predictor: TimeBasedPredictor = undefined;
        for (&predictor.hourly_patterns) |*hour| {
            hour.* = std.array_list.Managed(PatternObservation).init(allocator);
        }
        predictor.allocator = allocator;
        return predictor;
    }

    pub fn deinit(self: *Self) void {
        for (&self.hourly_patterns) |*hour| {
            for (hour.items) |*obs| {
                obs.deinit(self.allocator);
            }
            hour.deinit();
        }
    }

    /// Record observation with timestamp
    pub fn record(self: *Self, pattern: []const u8, cartridge_type: CartridgeType, timestamp_ms: u64) !void {
        const hour = @as(usize, @intCast((timestamp_ms / (60 * 60 * 1000)) % 24));

        const obs = PatternObservation{
            .pattern = try self.allocator.dupe(u8, pattern),
            .cartridge_type = cartridge_type,
            .timestamp_ms = timestamp_ms,
            .access_count = 1,
        };

        try self.hourly_patterns[hour].append(obs);
    }

    /// Predict patterns for current hour
    pub fn predictForHour(self: *Self, hour: usize, limit: usize) ![]const Prediction {
        var predictions = std.array_list.Managed(Prediction).init(self.allocator);

        if (hour >= 24) return error.InvalidHour;

        var pattern_counts = std.StringHashMap(usize).init(self.allocator);
        defer {
            var it = pattern_counts.iterator();
            while (it.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
            }
            pattern_counts.deinit();
        }

        // Count patterns for this hour
        for (self.hourly_patterns[hour].items) |obs| {
            const entry = try pattern_counts.getOrPut(obs.pattern);
            if (!entry.found_existing) {
                entry.value_ptr.* = 0;
            }
            entry.value_ptr.* += obs.access_count;
        }

        // Sort by frequency
        var entries = std.ArrayList(struct {
            pattern: []const u8,
            count: usize,
        }).init(self.allocator);

        var it = pattern_counts.iterator();
        while (it.next()) |entry| {
            try entries.append(.{
                .pattern = entry.key_ptr.*,
                .count = entry.value_ptr.*,
            });
        }

        std.sort.insertion(@TypeOf(entries.items[0]), entries.items, {}, struct {
            fn lessThan(_: void, a: anytype, b: anytype) bool {
                return b.count < a.count;
            }
        }.lessThan);

        // Generate predictions
        for (entries.items[0..@min(entries.items.len, limit)]) |e| {
            try predictions.append(Prediction{
                .pattern = try self.allocator.dupe(u8, e.pattern),
                .cartridge_type = .topic_index, // Default
                .confidence = @min(1.0, @as(f32, @floatFromInt(e.count)) / 10.0),
                .predicted_access_count = e.count,
                .reasoning = try std.fmt.allocPrint(
                    self.allocator,
                    "Historically accessed {d} times at hour {d}",
                    .{ e.count, hour }
                ),
            });
        }

        return predictions.toOwnedSlice();
    }
};

// ==================== Tests ====================//

test "PredictionEngine init and record" {
    var engine = PredictionEngine.init(std.testing.allocator);
    defer engine.deinit();

    try engine.recordObservation("test:query", .topic_index, 1000);

    try std.testing.expectEqual(@as(usize, 1), engine.pattern_history.items.len);
}

test "PredictionEngine generatePredictions" {
    var engine = PredictionEngine.init(std.testing.allocator);
    defer engine.deinit();

    const now = @as(u64, @intCast(std.time.nanoTimestamp() / 1_000_000));

    // Add enough observations to trigger prediction
    var i: usize = 0;
    while (i < 10) : (i += 1) {
        try engine.recordObservation("frequent:pattern", .topic_index, now - (@as(u64, i) * 1000));
    }

    const predictions = try engine.generatePredictions();

    try std.testing.expect(predictions.len > 0);
    try std.testing.expect(predictions[0].confidence > 0);
}

test "PredictionEngine pruneOldObservations" {
    var engine = PredictionEngine.init(std.testing.allocator);
    defer engine.deinit();

    const now = @as(u64, @intCast(std.time.nanoTimestamp() / 1_000_000));

    try engine.recordObservation("old", .topic_index, now - (25 * 60 * 60 * 1000)); // 25 hours ago
    try engine.recordObservation("recent", .topic_index, now);

    const removed = try engine.pruneOldObservations();

    try std.testing.expectEqual(@as(usize, 1), removed);
    try std.testing.expectEqual(@as(usize, 1), engine.pattern_history.items.len);
}

test "ProactiveBuilder init" {
    var builder = ProactiveBuilder.init(std.testing.allocator);
    defer builder.deinit();

    try std.testing.expectEqual(@as(usize, 0), builder.build_queue.items.len);
}

test "ProactiveBuilder record and queue" {
    var builder = ProactiveBuilder.init(std.testing.allocator);
    defer builder.deinit();

    try builder.recordQuery("test:pattern", .topic_index);

    // Add more to reach threshold
    var i: usize = 0;
    while (i < 5) : (i += 1) {
        try builder.recordQuery("test:pattern", .topic_index);
    }

    const queued = try builder.updateBuildQueue();

    try std.testing.expect(queued > 0);
}

test "ProactiveBuilder executeBuilds" {
    var builder = ProactiveBuilder.init(std.testing.allocator);
    defer builder.deinit();

    const result = try builder.executeBuilds(10);

    try std.testing.expectEqual(@as(usize, 0), result.built);
}

test "TimeBasedPredictor init" {
    var predictor = TimeBasedPredictor.init(std.testing.allocator);
    defer predictor.deinit();

    try std.testing.expectEqual(@as(usize, 24), predictor.hourly_patterns.len);
}

test "TimeBasedPredictor record and predict" {
    var predictor = TimeBasedPredictor.init(std.testing.allocator);
    defer predictor.deinit();

    const now = @as(u64, @intCast(std.time.nanoTimestamp() / 1_000_1000));
    const hour = @as(usize, @intCast((now / (60 * 60 * 1000)) % 24));

    var i: usize = 0;
    while (i < 5) : (i += 1) {
        try predictor.record("morning:query", .topic_index, now);
    }

    const predictions = try predictor.predictForHour(hour, 10);
    defer {
        for (predictions) |*p| p.deinit(std.testing.allocator);
        std.testing.allocator.free(predictions);
    }

    try std.testing.expect(predictions.len > 0);
}
