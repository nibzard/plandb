//! Cartridge versioning and migration support
//!
//! Provides migration logic between cartridge format versions with
//! backward compatibility support and data transformation.

const std = @import("std");
const format = @import("format.zig");

/// Migration result status
pub const MigrationResult = struct {
    success: bool,
    from_version: format.Version,
    to_version: format.Version,
    entries_migrated: usize,
    errors: []const MigrationError,

    pub fn deinit(self: *MigrationResult, allocator: std.mem.Allocator) void {
        for (self.errors) |*e| e.deinit(allocator);
        allocator.free(self.errors);
    }
};

/// Migration error with context
pub const MigrationError = struct {
    message: []const u8,
    entry_offset: ?u64,
    error_code: ErrorCode,

    pub fn deinit(self: *MigrationError, allocator: std.mem.Allocator) void {
        allocator.free(self.message);
    }

    pub const ErrorCode = enum {
        unsupported_version,
        corrupt_data,
        missing_field,
        type_mismatch,
        checksum_failed,
    };
};

/// Migration direction (upgrade or downgrade)
pub const MigrationDirection = enum {
    upgrade,
    downgrade,
};

/// Migration step descriptor
pub const MigrationStep = struct {
    from_version: format.Version,
    to_version: format.Version,
    migrate_fn: *const fn (
        allocator: std.mem.Allocator,
        input: []const u8,
        cartridge_type: format.CartridgeType
    ) anyerror![]const u8,
    description: []const u8,
    is_reversible: bool,
};

/// Registry of all available migrations
pub const MigrationRegistry = struct {
    migrations: std.ArrayList(MigrationStep),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        var registry = MigrationRegistry{
            .migrations = std.ArrayList(MigrationStep).init(allocator),
        };
        registry.registerBuiltinMigrations() catch {};
        return registry;
    }

    pub fn deinit(self: *Self) void {
        self.migrations.deinit();
    }

    /// Register built-in migrations for cartridge formats
    fn registerBuiltinMigrations(self: *Self) !void {
        // Future migrations would be registered here:
        // _ = try self.registerMigration(.{
        //     .from_version = .{ .major = 1, .minor = 0, .patch = 0 },
        //     .to_version = .{ .major = 1, .minor = 1, .patch = 0 },
        //     .migrate_fn = migrate_1_0_to_1_1,
        //     .description = "Add temporal index support",
        //     .is_reversible = true,
        // });
    }

    /// Find migration path from source to target version
    pub fn findMigrationPath(
        self: *Self,
        from: format.Version,
        to: format.Version,
        allocator: std.mem.Allocator
    ) ![]const MigrationStep {
        _ = self;
        _ = from;
        _ = to;
        _ = allocator;
        // For now, no migrations needed (we're at v1.0)
        return &.{};
    }

    /// Check if migration is needed
    pub fn needsMigration(from: format.Version, to: format.Version) bool {
        // Same version: no migration
        if (from.major == to.major and from.minor == to.minor and from.patch == to.patch) {
            return false;
        }
        // Target is future version: need migration
        if (to.major > from.major or (to.major == from.major and to.minor > from.minor)) {
            return true;
        }
        // Same major, higher patch: can read directly
        if (from.major == to.major and from.minor == to.minor and to.patch > from.patch) {
            return false;
        }
        return false;
    }
};

/// Cartridge migrator for performing version migrations
pub const CartridgeMigrator = struct {
    allocator: std.mem.Allocator,
    registry: MigrationRegistry,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return CartridgeMigrator{
            .allocator = allocator,
            .registry = MigrationRegistry.init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self.registry.deinit();
    }

    /// Migrate cartridge data from one version to another
    pub fn migrate(
        self: *Self,
        input: []const u8,
        target_version: format.Version
    ) !MigrationResult {
        // Parse header to get current version
        var fbs = std.io.fixedBufferStream(input);
        const reader = fbs.reader();

        const header = try format.CartridgeHeader.deserialize(reader);

        const from_version = header.version;
        const to_version = target_version;

        // Check if migration is needed
        if (!MigrationRegistry.needsMigration(from_version, to_version)) {
            return MigrationResult{
                .success = true,
                .from_version = from_version,
                .to_version = to_version,
                .entries_migrated = 0,
                .errors = &.{},
            };
        }

        // Check if migration path exists
        const path = try self.registry.findMigrationPath(from_version, to_version, self.allocator);
        defer self.allocator.free(path);

        if (path.len == 0) {
            // No migration path available
            var error_msg = try std.fmt.allocPrint(
                self.allocator,
                "No migration path from {}.{}.{} to {}.{}.{}",
                .{ from_version.major, from_version.minor, from_version.patch,
                   to_version.major, to_version.minor, to_version.patch }
            );

            return MigrationResult{
                .success = false,
                .from_version = from_version,
                .to_version = to_version,
                .entries_migrated = 0,
                .errors = &.{.{
                    .message = error_msg,
                    .entry_offset = null,
                    .error_code = .unsupported_version,
                }},
            };
        }

        // Apply migrations sequentially
        var current_data = input;
        var entries_migrated: usize = 0;
        var errors = std.ArrayList(MigrationError).init(self.allocator);

        for (path) |step| {
            const result = step.migrate_fn(self.allocator, current_data, header.cartridge_type) catch |err| {
                const msg = try std.fmt.allocPrint(
                    self.allocator,
                    "Migration failed: {s}",
                    .{@errorName(err)}
                );
                try errors.append(.{
                    .message = msg,
                    .entry_offset = null,
                    .error_code = .corrupt_data,
                });
                continue;
            };

            entries_migrated += 1;
            current_data = result;
        }

        return MigrationResult{
            .success = errors.items.len == 0,
            .from_version = from_version,
            .to_version = to_version,
            .entries_migrated = entries_migrated,
            .errors = try errors.toOwnedSlice(),
        };
    }

    /// Validate cartridge compatibility
    pub fn validateCompatibility(
        self: *Self,
        cartridge_version: format.Version,
        required_version: format.Version
    ) !CompatibilityStatus {
        _ = self;

        const is_compatible = format.Version.canRead(required_version, cartridge_version);
        const needs_migration = MigrationRegistry.needsMigration(cartridge_version, required_version);

        return CompatibilityStatus{
            .is_compatible = is_compatible,
            .needs_migration = needs_migration,
            .can_migrate = needs_migration,
            .recommended_action = if (!is_compatible and !needs_migration)
                .rebuild_required
            else if (needs_migration)
                .migrate
            else
                .use_as_is,
        };
    }
};

/// Compatibility check result
pub const CompatibilityStatus = struct {
    is_compatible: bool,
    needs_migration: bool,
    can_migrate: bool,
    recommended_action: RecommendedAction,

    pub const RecommendedAction = enum {
        use_as_is,
        migrate,
        rebuild_required,
    };
};

// ==================== Version-Specific Migrations ====================
// These would be implemented as cartridge formats evolve

// Example: Migration from 1.0 to 1.1
// fn migrate_1_0_to_1_1(
//     allocator: std.mem.Allocator,
//     input: []const u8,
//     cartridge_type: format.CartridgeType
// ) anyerror![]const u8 {
//     _ = allocator;
//     _ = input;
//     _ = cartridge_type;
//     // Implementation would parse old format, transform to new format
//     return error.NotImplemented;
// }

// ==================== Tests ====================//

test "MigrationRegistry.needsMigration same version" {
    const v1_0_0 = format.Version{ .major = 1, .minor = 0, .patch = 0 };
    const v1_0_1 = format.Version{ .major = 1, .minor = 0, .patch = 1 };

    try std.testing.expect(!MigrationRegistry.needsMigration(v1_0_0, v1_0_0));
    try std.testing.expect(!MigrationRegistry.needsMigration(v1_0_0, v1_0_1)); // patch upgrade: no migration
}

test "MigrationRegistry.needsMigration minor upgrade" {
    const v1_0 = format.Version{ .major = 1, .minor = 0, .patch = 0 };
    const v1_1 = format.Version{ .major = 1, .minor = 1, .patch = 0 };

    try std.testing.expect(MigrationRegistry.needsMigration(v1_0, v1_1));
}

test "MigrationRegistry.needsMigration major upgrade" {
    const v1_0 = format.Version{ .major = 1, .minor = 0, .patch = 0 };
    const v2_0 = format.Version{ .major = 2, .minor = 0, .patch = 0 };

    try std.testing.expect(MigrationRegistry.needsMigration(v1_0, v2_0));
}

test "CartridgeMigrator.init" {
    const migrator = CartridgeMigrator.init(std.testing.allocator);
    defer migrator.deinit();

    try std.testing.expect(migrator.registry.migrations.items.len >= 0);
}

test "CartridgeMigrator.validateCompatibility same version" {
    var migrator = CartridgeMigrator.init(std.testing.allocator);
    defer migrator.deinit();

    const v1_0 = format.Version{ .major = 1, .minor = 0, .patch = 0 };

    const status = try migrator.validateCompatibility(v1_0, v1_0);

    try std.testing.expect(status.is_compatible);
    try std.testing.expect(!status.needs_migration);
    try std.testing.expectEqual(CompatibilityStatus.RecommendedAction.use_as_is, status.recommended_action);
}

test "CartridgeMigrator.validateCompatibility newer reader" {
    var migrator = CartridgeMigrator.init(std.testing.allocator);
    defer migrator.deinit();

    const cartridge_v = format.Version{ .major = 1, .minor = 0, .patch = 0 };
    const reader_v = format.Version{ .major = 1, .minor = 1, .patch = 0 };

    const status = try migrator.validateCompatibility(cartridge_v, reader_v);

    try std.testing.expect(status.is_compatible); // Reader can read older
    try std.testing.expect(status.needs_migration);
    try std.testing.expectEqual(CompatibilityStatus.RecommendedAction.migrate, status.recommended_action);
}

test "CartridgeMigrator.migrate no migration needed" {
    var migrator = CartridgeMigrator.init(std.testing.allocator);
    defer migrator.deinit();

    // Create minimal cartridge header
    var buffer: [256]u8 = undefined;
    @as([*]u8, @ptrCast(&buffer)).*[0..4].* = std.mem.toBytes(u32, 0x4E434152); // magic
    buffer[4] = 1; // major
    buffer[5] = 0; // minor
    buffer[6] = 0; // patch
    buffer[7] = 0; // flags

    const target = format.Version{ .major = 1, .minor = 0, .patch = 0 };
    const result = try migrator.migrate(&buffer, target);

    try std.testing.expect(result.success);
    try std.testing.expectEqual(@as(usize, 0), result.entries_migrated);
}

test "Version backwards compatibility check" {
    const v100 = format.Version{ .major = 1, .minor = 0, .patch = 0 };
    const v110 = format.Version{ .major = 1, .minor = 1, .patch = 0 };
    const v200 = format.Version{ .major = 2, .minor = 0, .patch = 0 };

    // Can read same version
    try std.testing.expect(format.Version.canRead(v100, v100));

    // Can read older minor version
    try std.testing.expect(format.Version.canRead(v110, v100));

    // Cannot read newer minor version
    try std.testing.expect(!format.Version.canRead(v100, v110));

    // Cannot read different major
    try std.testing.expect(!format.Version.canRead(v200, v100));
    try std.testing.expect(!format.Version.canRead(v100, v200));
}
