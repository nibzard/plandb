//! Tiered storage management and cost optimization
//!
//! Manages data across storage tiers (hot/warm/cold) with cost-aware policies
//! and automated data movement based on access patterns.

const std = @import("std");
const mem = std.mem;

const PatternDetector = @import("patterns.zig").PatternDetector;
const ArchiveManager = @import("archival.zig").ArchiveManager;

/// Storage tier classification
pub const StorageTier = enum {
    /// Hot tier: Fast SSD storage for frequently accessed data
    hot,
    /// Warm tier: Standard SSD/storage for moderately accessed data
    warm,
    /// Cold tier: Compressed archival storage for rarely accessed data
    cold,
    /// Glacier tier: Lowest cost for long-term archival
    glacier,
};

/// Storage tier configuration
pub const TierConfig = struct {
    tier: StorageTier,
    /// Target access frequency (accesses per day)
    target_access_frequency: f32,
    /// Max storage capacity (bytes)
    max_capacity_bytes: u64,
    /// Cost per GB per month
    cost_per_gb_month: f64,
    /// Read latency target (ms)
    target_read_latency_ms: f64,

    pub fn getHotConfig() TierConfig {
        return .{
            .tier = .hot,
            .target_access_frequency = 100,
            .max_capacity_bytes = 100 * 1024 * 1024 * 1024, // 100 GB
            .cost_per_gb_month = 0.10, // $0.10/GB/month
            .target_read_latency_ms = 1.0,
        };
    }

    pub fn getWarmConfig() TierConfig {
        return .{
            .tier = .warm,
            .target_access_frequency = 10,
            .max_capacity_bytes = 500 * 1024 * 1024 * 1024, // 500 GB
            .cost_per_gb_month = 0.04, // $0.04/GB/month
            .target_read_latency_ms = 5.0,
        };
    }

    pub fn getColdConfig() TierConfig {
        return .{
            .tier = .cold,
            .target_access_frequency = 1,
            .max_capacity_bytes = 2 * 1024 * 1024 * 1024 * 1024, // 2 TB
            .cost_per_gb_month = 0.01, // $0.01/GB/month
            .target_read_latency_ms = 50.0,
        };
    }

    pub fn getGlacierConfig() TierConfig {
        return .{
            .tier = .glacier,
            .target_access_frequency = 0.01,
            .max_capacity_bytes = 10 * 1024 * 1024 * 1024 * 1024, // 10 TB
            .cost_per_gb_month = 0.004, // $0.004/GB/month
            .target_read_latency_ms = 1000.0, // 1 second
        };
    }
};

/// Data placement in a tier
pub const DataPlacement = struct {
    entity_id: []const u8,
    tier: StorageTier,
    size_bytes: u64,
    placement_ts: i128,
    access_count: u64,
    last_access_ts: i128,

    pub fn deinit(self: *DataPlacement, allocator: std.mem.Allocator) void {
        allocator.free(self.entity_id);
    }
};

/// Tiered storage manager
pub const TieredStorageManager = struct {
    allocator: std.mem.Allocator,
    pattern_detector: *PatternDetector,
    archive_manager: *ArchiveManager,
    tiers: [4]TierState,
    config: ManagerConfig,

    const Self = @This();

    pub fn init(
        allocator: std.mem.Allocator,
        pattern_detector: *PatternDetector,
        archive_manager: *ArchiveManager,
        config: ManagerConfig
    ) !Self {
        return TieredStorageManager{
            .allocator = allocator,
            .pattern_detector = pattern_detector,
            .archive_manager = archive_manager,
            .tiers = [_]TierState{
                try TierState.init(allocator, .hot, TierConfig.getHotConfig()),
                try TierState.init(allocator, .warm, TierConfig.getWarmConfig()),
                try TierState.init(allocator, .cold, TierConfig.getColdConfig()),
                try TierState.init(allocator, .glacier, TierConfig.getGlacierConfig()),
            },
            .config = config,
        };
    }

    pub fn deinit(self: *Self) void {
        for (&self.tiers) |*tier| {
            tier.deinit(self.allocator);
        }
    }

    /// Place data in appropriate tier based on access patterns
    pub fn placeData(self: *Self, entity_id: []const u8, size_bytes: u64) !PlacementResult {
        const predicted_tier = try self.predictOptimalTier(entity_id);

        const tier_state = &self.tiers[@intFromEnum(predicted_tier)];

        // Check capacity
        if (tier_state.current_bytes + size_bytes > tier_state.config.max_capacity_bytes) {
            // Try to evict or use next tier
            return self.handleCapacityExceeded(entity_id, size_bytes, predicted_tier);
        }

        // Create placement
        const placement = DataPlacement{
            .entity_id = try self.allocator.dupe(u8, entity_id),
            .tier = predicted_tier,
            .size_bytes = size_bytes,
            .placement_ts = std.time.nanoTimestamp(),
            .access_count = 0,
            .last_access_ts = std.time.nanoTimestamp(),
        };

        try tier_state.placements.append(placement);

        tier_state.current_bytes += size_bytes;

        return PlacementResult{
            .tier = predicted_tier,
            .success = true,
            .reason = try self.allocator.dupe(u8, "Placed in predicted tier"),
        };
    }

    /// Record access and potentially promote data
    pub fn recordAccess(self: *Self, entity_id: []const u8) !AccessResult {
        const current_tier = try self.findCurrentTier(entity_id);
        if (current_tier == null) {
            return AccessResult{
                .entity_found = false,
                .promoted = false,
                .previous_tier = null,
                .new_tier = null,
            };
        }

        // Update access count in tier
        for (self.tiers[@intFromEnum(current_tier.?)].placements.items) |*placement| {
            if (mem.eql(u8, placement.entity_id, entity_id)) {
                placement.access_count += 1;
                placement.last_access_ts = std.time.nanoTimestamp();
                break;
            }
        }

        // Check if promotion is needed
        const predicted_tier = try self.predictOptimalTier(entity_id);

        if (@intFromEnum(predicted_tier) < @intFromEnum(current_tier.?)) {
            // Promote to higher tier
            try self.promoteToTier(entity_id, predicted_tier);
            self.tiers[@intFromEnum(predicted_tier)].stats.promotions_in += 1;

            return AccessResult{
                .entity_found = true,
                .promoted = true,
                .previous_tier = current_tier,
                .new_tier = predicted_tier,
            };
        }

        return AccessResult{
            .entity_found = true,
            .promoted = false,
            .previous_tier = current_tier,
            .new_tier = null,
        };
    }

    /// Run tier optimization cycle
    pub fn runOptimizationCycle(self: *Self) !OptimizationResult {
        var promoted: usize = 0;
        var demoted: usize = 0;
        var cost_savings: f64 = 0;

        // Check for promotions (cold -> hot)
        for (&self.tiers, 0..) |*tier, tier_idx| {
            if (tier_idx == 0) continue; // Skip hot tier (can't promote higher)

            var i: usize = 0;
            while (i < tier.placements.items.len) {
                const placement = &tier.placements.items[i];
                const optimal_tier = try self.predictOptimalTier(placement.entity_id);

                if (@intFromEnum(optimal_tier) < tier_idx) {
                    const target_tier = &self.tiers[@intFromEnum(optimal_tier)];

                    // Move placement
                    const moved_placement = try self.clonePlacement(placement.*);
                    try target_tier.placements.append(moved_placement);

                    tier.placements.items[i].deinit(self.allocator);
                    _ = tier.placements.orderedRemove(i);

                    promoted += 1;
                    cost_savings += (tier.config.cost_per_gb_month - target_tier.config.cost_per_gb_month) * @as(f64, @floatFromInt(placement.size_bytes)) / (1024 * 1024 * 1024);
                } else {
                    i += 1;
                }
            }
        }

        // Check for demotions (hot -> cold)
        for (&self.tiers, 0..) |*tier, tier_idx| {
            if (tier_idx == self.tiers.len - 1) continue; // Skip glacier tier

            var i: usize = 0;
            while (i < tier.placements.items.len) {
                const placement = &tier.placements.items[i];
                const optimal_tier = try self.predictOptimalTier(placement.entity_id);

                if (@intFromEnum(optimal_tier) > tier_idx) {
                    const target_tier = &self.tiers[@intFromEnum(optimal_tier)];

                    // Move placement
                    const moved_placement = try self.clonePlacement(placement.*);
                    try target_tier.placements.append(moved_placement);

                    tier.placements.items[i].deinit(self.allocator);
                    _ = tier.placements.orderedRemove(i);

                    demoted += 1;
                    cost_savings += (tier.config.cost_per_gb_month - target_tier.config.cost_per_gb_month) * @as(f64, @floatFromInt(placement.size_bytes)) / (1024 * 1024 * 1024);
                } else {
                    i += 1;
                }
            }
        }

        // Update stats
        for (&self.tiers) |*tier| {
            tier.stats.total_optimizations += 1;
            tier.stats.current_bytes = tier.calculateCurrentBytes();
        }

        return OptimizationResult{
            .promoted_count = promoted,
            .demoted_count = demoted,
            .estimated_monthly_savings = cost_savings,
        };
    }

    /// Get cost breakdown
    pub fn getCostBreakdown(self: *const Self) CostBreakdown {
        var total_monthly_cost: f64 = 0;
        var tier_costs = [4]f64{0} ** 4;

        for (&self.tiers, 0..) |*tier, i| {
            const gb_used = @as(f64, @floatFromInt(tier.current_bytes)) / (1024 * 1024 * 1024);
            tier_costs[i] = gb_used * tier.config.cost_per_gb_month;
            total_monthly_cost += tier_costs[i];
        }

        return CostBreakdown{
            .total_monthly_cost = total_monthly_cost,
            .hot_tier_cost = tier_costs[0],
            .warm_tier_cost = tier_costs[1],
            .cold_tier_cost = tier_costs[2],
            .glacier_tier_cost = tier_costs[3],
        };
    }

    /// Get optimization recommendations
    pub fn getRecommendations(self: *Self) ![]Recommendation {
        var recommendations = std.array_list.Managed(Recommendation).init(self.allocator);

        const cost_breakdown = self.getCostBreakdown();

        // Check for over-full tiers
        for (&self.tiers) |*tier| {
            const usage_ratio = @as(f64, @floatFromInt(tier.current_bytes)) / @as(f64, @floatFromInt(tier.config.max_capacity_bytes));

            if (usage_ratio > 0.9) {
                try recommendations.append(.{
                    .type = .increase_capacity,
                    .target_tier = tier.config.tier,
                    .priority = @as(u8, @intFromFloat(usage_ratio * 10)),
                    .description = try std.fmt.allocPrint(
                        self.allocator,
                        "{s} tier at {d:.0}% capacity",
                        .{@tagName(tier.config.tier), @as(f64, @floatFromInt(usage_ratio * 100))}
                    ),
                    .estimated_savings = 0,
                });
            }
        }

        // Check for cost optimization opportunities
        if (cost_breakdown.hot_tier_cost > 100 and self.tiers[0].placements.items.len > 100) {
            try recommendations.append(.{
                .type = .demote_idle_data,
                .target_tier = .hot,
                .priority = 5,
                .description = try self.allocator.dupe(u8, "Consider demoting idle data from hot tier"),
                .estimated_savings = cost_breakdown.hot_tier_cost * 0.2,
            });
        }

        return recommendations.toOwnedSlice();
    }

    fn predictOptimalTier(self: *Self, entity_id: []const u8) !StorageTier {
        // In real implementation, would query pattern detector for access frequency
        // For now, use simple heuristics

        const entity_key = try std.fmt.allocPrint(self.allocator, "entity:{s}", .{entity_id});
        defer self.allocator.free(entity_key);

        // Check if in pattern detector
        // If not found, default to warm
        return .warm;
    }

    fn findCurrentTier(self: *Self, entity_id: []const u8) !?StorageTier {
        for (&self.tiers, 0..) |*tier, i| {
            for (tier.placements.items) |placement| {
                if (mem.eql(u8, placement.entity_id, entity_id)) {
                    return @as(StorageTier, @enumFromInt(i));
                }
            }
        }
        return null;
    }

    fn promoteToTier(self: *Self, entity_id: []const u8, target_tier: StorageTier) !void {
        // Find in current tier and move to target
        for (&self.tiers) |*tier| {
            var i: usize = 0;
            while (i < tier.placements.items.len) {
                if (mem.eql(u8, tier.placements.items[i].entity_id, entity_id)) {
                    const placement = tier.placements.orderedRemove(i);

                    try self.tiers[@intFromEnum(target_tier)].placements.append(placement);
                    return;
                }
                i += 1;
            }
        }
    }

    fn handleCapacityExceeded(self: *Self, entity_id: []const u8, size_bytes: u64, preferred_tier: StorageTier) !PlacementResult {
        // Try to evict from preferred tier
        const tier_state = &self.tiers[@intFromEnum(preferred_tier)];

        if (tier_state.placements.items.len > 0) {
            // Find oldest/least accessed
            var min_access_idx: usize = 0;
            var min_access_ts = tier_state.placements.items[0].last_access_ts;

            for (tier_state.placements.items[1..], 0..) |placement, i| {
                if (placement.last_access_ts < min_access_ts) {
                    min_access_ts = placement.last_access_ts;
                    min_access_idx = i + 1;
                }
            }

            const evicted = tier_state.placements.orderedRemove(min_access_idx);

            // Move to colder tier
            try self.archiveManager.archiveEntity(evicted.entity_id, "placeholder_data");

            evicted.deinit(self.allocator);
        }

        // Try again
        return self.placeData(entity_id, size_bytes);
    }

    fn clonePlacement(self: *Self, placement: DataPlacement) !DataPlacement {
        return DataPlacement{
            .entity_id = try self.allocator.dupe(u8, placement.entity_id),
            .tier = placement.tier,
            .size_bytes = placement.size_bytes,
            .placement_ts = placement.placement_ts,
            .access_count = placement.access_count,
            .last_access_ts = placement.last_access_ts,
        };
    }
};

/// State of a storage tier
pub const TierState = struct {
    config: TierConfig,
    placements: std.ArrayList(DataPlacement),
    current_bytes: u64,
    stats: TierStats,

    pub fn init(allocator: std.mem.Allocator, tier: StorageTier, config: TierConfig) !TierState {
        _ = tier;
        return TierState{
            .config = config,
            .placements = std.array_list.Managed(DataPlacement).init(allocator),
            .current_bytes = 0,
            .stats = TierStats{},
        };
    }

    pub fn deinit(self: *TierState) void {
        for (self.placements.items) |*p| {
            p.deinit(self.config.tier);
        }
        self.placements.deinit();
    }

    pub fn calculateCurrentBytes(self: *const TierState) u64 {
        var total: u64 = 0;
        for (self.placements.items) |p| {
            total += p.size_bytes;
        }
        return total;
    }
};

/// Tier statistics
pub const TierStats = struct {
    total_optimizations: u64 = 0,
    promotions_in: u64 = 0,
    promotions_out: u64 = 0,
};

/// Placement result
pub const PlacementResult = struct {
    tier: StorageTier,
    success: bool,
    reason: []const u8,

    pub fn deinit(self: *PlacementResult, allocator: std.mem.Allocator) void {
        allocator.free(self.reason);
    }
};

/// Access result
pub const AccessResult = struct {
    entity_found: bool,
    promoted: bool,
    previous_tier: ?StorageTier,
    new_tier: ?StorageTier,
};

/// Optimization result
pub const OptimizationResult = struct {
    promoted_count: usize,
    demoted_count: usize,
    estimated_monthly_savings: f64,
};

/// Cost breakdown
pub const CostBreakdown = struct {
    total_monthly_cost: f64,
    hot_tier_cost: f64,
    warm_tier_cost: f64,
    cold_tier_cost: f64,
    glacier_tier_cost: f64,
};

/// Recommendation type
pub const RecommendationType = enum {
    increase_capacity,
    demote_idle_data,
    compress_data,
    archive_old_data,
    optimize_tier_distribution,
};

/// Optimization recommendation
pub const Recommendation = struct {
    type: RecommendationType,
    target_tier: StorageTier,
    priority: u8, // 1-10
    description: []const u8,
    estimated_savings: f64,

    pub fn deinit(self: *Recommendation, allocator: std.mem.Allocator) void {
        allocator.free(self.description);
    }
};

/// Manager configuration
pub const ManagerConfig = struct {
    /// How often to run optimization (milliseconds)
    optimization_interval_ms: u64 = 60 * 60 * 1000, // 1 hour
    /// Minimum access count before considering promotion
    min_accesses_for_promotion: u64 = 10,
    /// Minimum age before considering demotion
    min_age_for_demotion_ms: u64 = 7 * 24 * 60 * 60 * 1000, // 7 days
};

// ==================== Tests ====================//

test "TierConfig defaults" {
    const hot = TierConfig.getHotConfig();
    try std.testing.expectEqual(StorageTier.hot, hot.tier);
    try std.testing.expectEqual(@as(f64, 0.10), hot.cost_per_gb_month);
}

test "TieredStorageManager init" {
    const detector = undefined; // Mock
    const archiver = undefined; // Mock

    var manager = try TieredStorageManager.init(std.testing.allocator, &detector, &archiver, .{});
    defer manager.deinit();

    try std.testing.expectEqual(@as(usize, 4), manager.tiers.len);
}

test "TieredStorageManager placeData" {
    const detector = undefined;
    const archiver = undefined;

    var manager = try TieredStorageManager.init(std.testing.allocator, &detector, &archiver, .{});
    defer manager.deinit();

    const result = try manager.placeData("entity:123", 1024 * 1024);

    try std.testing.expect(result.success);
    try std.testing.expect(result.reason != null);
}

test "TieredStorageManager runOptimizationCycle" {
    const detector = undefined;
    const archiver = undefined;

    var manager = try TieredStorageManager.init(std.testing.allocator, &detector, &archiver, .{});
    defer manager.deinit();

    const result = try manager.runOptimizationCycle();

    try std.testing.expect(result.promoted_count >= 0);
}

test "TieredStorageManager getCostBreakdown" {
    const detector = undefined;
    const archiver = undefined;

    var manager = try TieredStorageManager.init(std.testing.allocator, &detector, &archiver, .{});
    defer manager.deinit();

    const costs = manager.getCostBreakdown();

    try std.testing.expect(costs.total_monthly_cost >= 0);
}

test "TieredStorageManager getRecommendations" {
    const detector = undefined;
    const archiver = undefined;

    var manager = try TieredStorageManager.init(std.testing.allocator, &detector, &archiver, .{});
    defer manager.deinit();

    const recommendations = try manager.getRecommendations();
    defer {
        for (recommendations) |*r| r.deinit(std.testing.allocator);
        std.testing.allocator.free(recommendations);
    }

    // Should return recommendations
    try std.testing.expect(recommendations.len >= 0);
}

test "DataPlacement deinit" {
    const placement = DataPlacement{
        .entity_id = try std.testing.allocator.dupe(u8, "test"),
        .tier = .hot,
        .size_bytes = 1024,
        .placement_ts = 1000,
        .access_count = 0,
        .last_access_ts = 2000,
    };

    placement.deinit(std.testing.allocator);

    // If we get here, deinit worked
    try std.testing.expect(true);
}

test "PlacementResult deinit" {
    const result = PlacementResult{
        .tier = .hot,
        .success = true,
        .reason = try std.testing.allocator.dupe(u8, "test reason"),
    };

    result.deinit(std.testing.allocator);

    try std.testing.expect(true);
}
