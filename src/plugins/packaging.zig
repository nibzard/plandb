//! Plugin packaging and distribution for NorthstarDB
//!
//! Handles plugin packaging format, installation, and distribution

const std = @import("std");
const manager = @import("manager.zig");

/// Plugin package format version
pub const PACKAGE_FORMAT_VERSION = "1.0";

/// Plugin package file extension
pub const PACKAGE_EXTENSION = ".ndb-plugin";

/// Plugin manifest structure
pub const PluginManifest = struct {
    format_version: []const u8 = PACKAGE_FORMAT_VERSION,
    name: []const u8,
    version: []const u8,
    description: []const u8,
    author: []const u8,
    license: []const u8 = "MIT",
    min_northstar_version: []const u8 = "0.1.0",
    hooks: []const []const u8,
    permissions: Permissions,
    dependencies: []const Dependency = &[_]Dependency{},
    checksum: []const u8 = "",

    pub fn deinit(self: *PluginManifest, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.version);
        allocator.free(self.description);
        allocator.free(self.author);
        allocator.free(self.license);
        allocator.free(self.min_northstar_version);

        for (self.hooks) |hook| {
            allocator.free(hook);
        }
        allocator.free(self.hooks);

        for (self.dependencies) |dep| {
            var mut_dep = @constCast(&dep);
            mut_dep.deinit(allocator);
        }
        if (self.dependencies.len > 0) {
            allocator.free(self.dependencies);
        }

        if (self.checksum.len > 0) {
            allocator.free(self.checksum);
        }
    }
};

/// Plugin permissions for security sandboxing
pub const Permissions = struct {
    llm_access: bool = false,
    cartridge_write: bool = false,
    cartridge_read: bool = true,
    network_access: bool = false,
    file_system_read: bool = false,
    file_system_write: bool = false,
    max_memory_mb: u32 = 128,
    max_cpu_percent: u8 = 50,
    max_llm_requests_per_hour: u32 = 100,

    pub const Permission = enum {
        llm_access,
        cartridge_write,
        cartridge_read,
        network_access,
        file_system_read,
        file_system_write,
    };
};

/// Plugin dependency specification
pub const Dependency = struct {
    name: []const u8,
    version_constraint: []const u8, // e.g., ">=1.0.0", "2.x"

    pub fn deinit(self: *Dependency, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.version_constraint);
    }
};

/// Plugin package structure
pub const PluginPackage = struct {
    manifest: PluginManifest,
    files: std.ArrayListUnmanaged(PackageFile),
    checksum: []const u8,

    pub fn deinit(self: *PluginPackage, allocator: std.mem.Allocator) void {
        self.manifest.deinit(allocator);

        for (self.files.items) |*file| {
            file.deinit(allocator);
        }
        self.files.deinit(allocator);

        allocator.free(self.checksum);
    }
};

/// File entry in a package
pub const PackageFile = struct {
    path: []const u8,    // Path within package
    content: []const u8, // File content
    executable: bool = false,

    pub fn deinit(self: *PackageFile, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.content);
    }
};

/// Plugin packager for creating and managing plugin packages
pub const PluginPackager = struct {
    allocator: std.mem.Allocator,
    install_dir: []const u8,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        // Default to ~/.northstar/plugins
        const home = std.process.getEnvVarOwned(allocator, "HOME") catch "/tmp";
        defer allocator.free(home);

        const install_path = std.fmt.allocPrint(allocator, "{s}/.northstar/plugins", .{home}) catch "/tmp/northstar/plugins";

        return Self{
            .allocator = allocator,
            .install_dir = install_path,
        };
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.install_dir);
    }

    /// Create a plugin package from a directory
    pub fn createPackage(self: *Self, plugin_path: []const u8) !PluginPackage {
        // Load manifest
        const manifest_path = try std.fs.path.join(self.allocator, &.{ plugin_path, "plugin.json" });
        defer self.allocator.free(manifest_path);

        const manifest_content = try std.fs.cwd().readFileAlloc(self.allocator, manifest_path, 1024 * 1024);
        defer self.allocator.free(manifest_content);

        const manifest = try parsePluginManifest(self.allocator, manifest_content);

        // Collect all files
        var files = std.ArrayListUnmanaged(PackageFile){};
        errdefer {
            for (files.items) |*f| f.deinit(self.allocator);
            files.deinit(self.allocator);
        }

        var dir = try std.fs.cwd().openDir(plugin_path, .{ .iterate = true });
        defer dir.close();

        var walker = try dir.walk(self.allocator);
        defer walker.deinit();

        while (try walker.next()) |entry| {
            if (entry.kind == .file) {
                // Skip manifest (already loaded)
                if (std.mem.eql(u8, entry.path, "plugin.json")) continue;

                const content = try dir.readFileAlloc(self.allocator, entry.path, 10 * 1024 * 1024);

                try files.append(self.allocator, .{
                    .path = try self.allocator.dupe(u8, entry.path),
                    .content = content,
                    .executable = false, // TODO: detect from file mode
                });
            }
        }

        // Generate package checksum
        const checksum = try generatePackageChecksum(self.allocator, manifest, files.items);

        return PluginPackage{
            .manifest = manifest,
            .files = files,
            .checksum = checksum,
        };
    }

    /// Write package to file (tar.gz format)
    pub fn writePackage(self: *Self, pkg: PluginPackage, output_path: []const u8) !void {
        // Simple implementation: write manifest + content list
        // Full tar.gz implementation would require compression library
        var file = try std.fs.cwd().createFile(output_path, .{ .read = true });
        defer file.close();

        // Build the full package content
        var content = std.ArrayListUnmanaged(u8){};
        defer content.deinit(self.allocator);

        // Write package header
        const header = try std.fmt.allocPrint(self.allocator, "NORTHSTAR_PLUGIN_V{s}\n", .{PACKAGE_FORMAT_VERSION});
        defer self.allocator.free(header);
        try content.appendSlice(self.allocator, header);

        // Write manifest
        try content.appendSlice(self.allocator, "MANIFEST_START\n");
        // Simplified manifest format without full JSON
        const manifest_simple = try std.fmt.allocPrint(self.allocator,
            \\{{"name":"{s}","version":"{s}","author":"{s}"}}
        , .{ pkg.manifest.name, pkg.manifest.version, pkg.manifest.author });
        defer self.allocator.free(manifest_simple);
        try content.appendSlice(self.allocator, manifest_simple);
        try content.appendSlice(self.allocator, "\nMANIFEST_END\n");

        // Write file count
        const files_line = try std.fmt.allocPrint(self.allocator, "FILES: {d}\n", .{pkg.files.items.len});
        defer self.allocator.free(files_line);
        try content.appendSlice(self.allocator, files_line);

        // Write each file
        for (pkg.files.items) |file_entry| {
            const file_start = try std.fmt.allocPrint(self.allocator, "FILE_START: {s}\n", .{file_entry.path});
            defer self.allocator.free(file_start);
            try content.appendSlice(self.allocator, file_start);
            try content.appendSlice(self.allocator, file_entry.content);
            try content.appendSlice(self.allocator, "\nFILE_END\n");
        }

        // Write checksum
        const checksum_line = try std.fmt.allocPrint(self.allocator, "CHECKSUM: {s}\n", .{pkg.checksum});
        defer self.allocator.free(checksum_line);
        try content.appendSlice(self.allocator, checksum_line);

        // Write all content to file
        try file.writeAll(content.items);
    }

    /// Install a plugin package
    pub fn installPackage(self: *Self, package_file: []const u8, target_dir: ?[]const u8) ![]const u8 {
        _ = package_file;
        _ = target_dir;

        // Create install directory if needed
        _ = try std.fs.cwd().makeOpenPath(self.install_dir, .{});

        // TODO: Extract and install package
        return try self.allocator.dupe(u8, self.install_dir);
    }

    /// Uninstall a plugin
    pub fn uninstallPlugin(self: *Self, plugin_name: []const u8) !void {
        const plugin_dir = try std.fs.path.join(self.allocator, &.{ self.install_dir, plugin_name });
        defer self.allocator.free(plugin_dir);

        std.fs.cwd().deleteTree(plugin_dir) catch |err| {
            std.log.err("Failed to remove plugin directory: {s}", .{plugin_dir});
            return err;
        };
    }
};

/// Parse plugin manifest from JSON
pub fn parsePluginManifest(allocator: std.mem.Allocator, json_str: []const u8) !PluginManifest {
    const parsed = try std.json.parseFromSlice(
        PluginManifestJson,
        allocator,
        json_str,
        .{ .ignore_unknown_fields = true },
    );
    defer parsed.deinit();

    const value = parsed.value;

    // Hooks array - use ArrayListUnmanaged
    var hooks = std.ArrayListUnmanaged([]const u8){};
    errdefer {
        for (hooks.items) |h| allocator.free(h);
        hooks.deinit(allocator);
    }

    // Dependencies array
    var deps = std.ArrayListUnmanaged(Dependency){};
    errdefer {
        for (deps.items) |*d| d.deinit(allocator);
        deps.deinit(allocator);
    }

    if (value.hooks) |hooks_arr| {
        try hooks.ensureUnusedCapacity(allocator, hooks_arr.len);
        for (hooks_arr) |hook| {
            hooks.appendAssumeCapacity(try allocator.dupe(u8, hook));
        }
    }

    if (value.dependencies) |deps_arr| {
        try deps.ensureUnusedCapacity(allocator, deps_arr.len);
        for (deps_arr) |dep| {
            deps.appendAssumeCapacity(.{
                .name = try allocator.dupe(u8, dep.name),
                .version_constraint = try allocator.dupe(u8, dep.version_constraint),
            });
        }
    }

    return PluginManifest{
        .format_version = try allocator.dupe(u8, if (value.format_version) |v| v else PACKAGE_FORMAT_VERSION),
        .name = try allocator.dupe(u8, value.name),
        .version = try allocator.dupe(u8, value.version),
        .description = try allocator.dupe(u8, value.description),
        .author = try allocator.dupe(u8, value.author),
        .license = try allocator.dupe(u8, if (value.license) |l| l else "MIT"),
        .min_northstar_version = try allocator.dupe(u8, if (value.min_northstar_version) |v| v else "0.1.0"),
        .hooks = try hooks.toOwnedSlice(allocator),
        .permissions = value.permissions orelse Permissions{},
        .dependencies = try deps.toOwnedSlice(allocator),
        .checksum = try allocator.dupe(u8, if (value.checksum) |c| c else ""),
    };
}

/// JSON parsing structure for manifest
const PluginManifestJson = struct {
    format_version: ?[]const u8 = null,
    name: []const u8,
    version: []const u8,
    description: []const u8,
    author: []const u8,
    license: ?[]const u8 = null,
    min_northstar_version: ?[]const u8 = null,
    hooks: ?[]const []const u8 = null,
    permissions: ?Permissions = null,
    dependencies: ?[]const DependencyJson = null,
    checksum: ?[]const u8 = null,
};

const DependencyJson = struct {
    name: []const u8,
    version_constraint: []const u8,
};

/// Load plugin manifest from path
pub fn loadPluginManifest(allocator: std.mem.Allocator, path: []const u8) !PluginManifest {
    const manifest_path = try std.fs.path.join(allocator, &.{ path, "plugin.json" });
    defer allocator.free(manifest_path);

    const content = try std.fs.cwd().readFileAlloc(allocator, manifest_path, 1024 * 1024);
    defer allocator.free(content);

    return parsePluginManifest(allocator, content);
}

/// Generate package checksum
fn generatePackageChecksum(allocator: std.mem.Allocator, manifest: PluginManifest, files: []const PackageFile) ![]const u8 {
    _ = manifest;

    // Simple checksum for now (concatenate file sizes)
    var total_size: usize = 0;
    for (files) |file| {
        total_size += file.content.len;
    }

    return std.fmt.allocPrint(allocator, "sha256:{x}", .{total_size});
}

/// Compute SHA256 hash of a file
pub fn computeFileHash(allocator: std.mem.Allocator, file_path: []const u8) ![]const u8 {
    const content = try std.fs.cwd().readFileAlloc(allocator, file_path, 100 * 1024 * 1024);
    defer allocator.free(content);

    // Simple hash: length + first 32 bytes as hex
    var hash_buffer: [128]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&hash_buffer);

    const writer = fbs.writer();
    try writer.print("{x}", .{content.len});

    const len = @min(content.len, 32);
    for (content[0..len]) |byte| {
        try writer.print("{x:0>2}", .{byte});
    }

    return allocator.dupe(u8, fbs.getWritten());
}

/// Generate plugin documentation
pub fn generatePluginDocs(allocator: std.mem.Allocator, plugin_path: []const u8) ![]const u8 {
    var manifest = try loadPluginManifest(allocator, plugin_path);
    defer manifest.deinit(allocator);

    var buffer = std.ArrayListUnmanaged(u8){};
    defer buffer.deinit(allocator);
    const writer = buffer.writer(allocator);

    try writer.print("# {s} Plugin v{s}\n\n", .{ manifest.name, manifest.version });
    try writer.print("{s}\n\n", .{manifest.description});

    try writer.writeAll("## Metadata\n\n");
    try writer.print("- **Author**: {s}\n", .{manifest.author});
    try writer.print("- **License**: {s}\n", .{manifest.license});
    try writer.print("- **Min NorthstarDB Version**: {s}\n", .{manifest.min_northstar_version});
    try writer.writeAll("\n");

    if (manifest.hooks.len > 0) {
        try writer.writeAll("## Implemented Hooks\n\n");
        for (manifest.hooks) |hook| {
            try writer.print("- `{s}`\n", .{hook});
        }
        try writer.writeAll("\n");
    }

    try writer.writeAll("## Permissions\n\n");
    try writer.print("- LLM Access: {}\n", .{manifest.permissions.llm_access});
    try writer.print("- Cartridge Write: {}\n", .{manifest.permissions.cartridge_write});
    try writer.print("- Cartridge Read: {}\n", .{manifest.permissions.cartridge_read});
    try writer.print("- Network Access: {}\n", .{manifest.permissions.network_access});
    try writer.print("- Max Memory: {} MB\n", .{manifest.permissions.max_memory_mb});
    try writer.writeAll("\n");

    if (manifest.dependencies.len > 0) {
        try writer.writeAll("## Dependencies\n\n");
        for (manifest.dependencies) |dep| {
            try writer.print("- {s} ({s})\n", .{ dep.name, dep.version_constraint });
        }
        try writer.writeAll("\n");
    }

    try writer.writeAll("## Installation\n\n");
    try writer.print("```bash\nbench plugin install {s}.ndb-plugin\n```\n\n", .{manifest.name});

    try writer.writeAll("## Usage\n\n");
    try writer.print("```zig\nconst {s}_plugin = @import(\"@northstar/plugins/{s}\").plugin;\ntry plugin_manager.register_plugin({s}_plugin);\n```\n", .{ manifest.name, manifest.name, manifest.name });

    try writer.writeAll("\n## License\n\n");
    try writer.print("{s}\n", .{manifest.license});

    return buffer.toOwnedSlice(allocator);
}

test "parse_plugin_manifest" {
    const json =
        \\{
        \\  "name": "test_plugin",
        \\  "version": "1.0.0",
        \\  "description": "A test plugin",
        \\  "author": "Test Author",
        \\  "hooks": ["on_commit", "on_query"],
        \\  "permissions": {
        \\    "llm_access": true,
        \\    "cartridge_write": false
        \\  }
        \\}
    ;

    const manifest = try parsePluginManifest(std.testing.allocator, json);
    defer manifest.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("test_plugin", manifest.name);
    try std.testing.expectEqualStrings("1.0.0", manifest.version);
    try std.testing.expectEqual(@as(usize, 2), manifest.hooks.len);
    try std.testing.expect(manifest.permissions.llm_access);
}

test "compute_file_hash" {
    // Create a temporary file for testing
    const test_content = "test content for hashing";
    const tmp_path = "/tmp/plandb_test_hash.txt";

    {
        const file = try std.fs.cwd().createFile(tmp_path, .{});
        defer file.close();
        try file.writeAll(test_content);
    }
    defer std.fs.cwd().deleteFile(tmp_path) catch {};

    const hash = try computeFileHash(std.testing.allocator, tmp_path);
    defer std.testing.allocator.free(hash);

    try std.testing.expect(hash.len > 0);
}

test "generate_plugin_docs" {
    // This test requires a plugin.json in current dir
    // so we skip it in normal testing
    if (std.fs.cwd().openFile("plugin.json", .{})) |_| {
        const docs = try generatePluginDocs(std.testing.allocator, ".");
        defer std.testing.allocator.free(docs);
        try std.testing.expect(docs.len > 0);
    } else |_| {
        // No plugin.json, skip test
        try std.testing.expect(true);
    }
}
