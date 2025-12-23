//! Plugin marketplace for NorthstarDB AI intelligence layer
//!
//! Provides plugin registry, discovery, distribution, and sharing capabilities

const std = @import("std");

/// Plugin marketplace with registry, discovery, and distribution
pub const PluginMarketplace = struct {
    allocator: std.mem.Allocator,
    registry: PluginRegistry,
    local_cache: PluginCache,
    config: MarketplaceConfig,

    const Self = @This();

    /// Initialize marketplace with default configuration
    pub fn init(allocator: std.mem.Allocator, config: MarketplaceConfig) !Self {
        var registry = try PluginRegistry.init(allocator, config.registry_path);
        errdefer registry.deinit();

        var local_cache = try PluginCache.init(allocator, config.cache_path);
        errdefer local_cache.deinit();

        return Self{
            .allocator = allocator,
            .registry = registry,
            .local_cache = local_cache,
            .config = config,
        };
    }

    pub fn deinit(self: *Self) void {
        self.registry.deinit();
        self.local_cache.deinit();
    }

    /// Search for plugins by query string
    pub fn search(self: *Self, query: []const u8, options: SearchOptions) ![]PluginManifest {
        return self.registry.search(self.allocator, query, options);
    }

    /// Get plugin manifest by ID
    pub fn get_manifest(self: *Self, plugin_id: []const u8) !?PluginManifest {
        return self.registry.get(plugin_id);
    }

    /// Download and install a plugin
    pub fn install(self: *Self, plugin_id: []const u8, version: ?[]const u8) !InstallResult {
        // Get manifest
        const manifest = (try self.registry.get(plugin_id)) orelse return error.PluginNotFound;

        // Resolve version
        const target_version = version orelse manifest.latest_version;

        // Check if already installed
        if (try self.local_cache.is_installed(plugin_id, target_version)) {
            return InstallResult{
                .status = .already_installed,
                .plugin_path = try self.local_cache.get_plugin_path(plugin_id, target_version),
            };
        }

        // Resolve dependencies
        const deps = try self.resolve_dependencies(manifest, target_version);
        defer {
            for (deps) |*dep| {
                self.allocator.free(dep.plugin_id);
                self.allocator.free(dep.version);
            }
            self.allocator.free(deps);
        }

        // Download plugin
        const plugin_path = try self.download_plugin(manifest, target_version);

        // Verify checksum
        try self.verify_plugin(plugin_path, manifest);

        // Install to cache
        try self.local_cache.install(plugin_id, target_version, plugin_path);

        return InstallResult{
            .status = .success,
            .plugin_path = try self.local_cache.get_plugin_path(plugin_id, target_version),
        };
    }

    /// Uninstall a plugin
    pub fn uninstall(self: *Self, plugin_id: []const u8, version: ?[]const u8) !void {
        const manifest = (try self.registry.get(plugin_id)) orelse return error.PluginNotFound;
        const target_version = version orelse manifest.latest_version;
        try self.local_cache.uninstall(plugin_id, target_version);
    }

    /// Publish a plugin to the marketplace
    pub fn publish(self: *Self, plugin_path: []const u8, metadata: PublishMetadata) !PublishResult {
        // Validate plugin
        const plugin = try self.validate_plugin(plugin_path);
        defer plugin.deinit(self.allocator);

        // Check if plugin ID already exists
        if (try self.registry.get(metadata.id)) |_| {
            return error.PluginAlreadyExists;
        }

        // Create manifest
        var manifest = try PluginManifest.from_metadata(self.allocator, metadata, plugin);
        errdefer manifest.deinit(self.allocator);

        // Upload to registry
        try self.registry.publish(manifest);

        return PublishResult{
            .plugin_id = try self.allocator.dupe(u8, metadata.id),
            .version = try self.allocator.dupe(u8, manifest.latest_version),
            .status = .published,
        };
    }

    /// Update a plugin to the latest version
    pub fn update(self: *Self, plugin_id: []const u8) !UpdateResult {
        const manifest = (try self.registry.get(plugin_id)) orelse return error.PluginNotFound;

        // Get currently installed version
        const current_version = (try self.local_cache.get_installed_version(plugin_id)) orelse
            return error.PluginNotInstalled;

        // Check if update available
        if (std.mem.eql(u8, current_version, manifest.latest_version)) {
            return UpdateResult{
                .status = .up_to_date,
                .current_version = current_version,
            };
        }

        // Install new version
        const result = try self.install(plugin_id, manifest.latest_version);

        return UpdateResult{
            .status = .updated,
            .current_version = try self.allocator.dupe(u8, manifest.latest_version),
            .previous_version = current_version,
            .plugin_path = result.plugin_path,
        };
    }

    /// List installed plugins
    pub fn list_installed(self: *Self) ![]InstalledPlugin {
        return self.local_cache.list_installed(self.allocator);
    }

    /// Resolve plugin dependencies
    fn resolve_dependencies(self: *Self, manifest: PluginManifest, version: []const u8) ![]Dependency {
        const version_info = manifest.getVersionInfo(version) orelse return error.VersionNotFound;

        var deps = std.ArrayListUnmanaged(Dependency).init(self.allocator);

        for (version_info.dependencies) |dep| {
            const dep_copy = Dependency{
                .plugin_id = try self.allocator.dupe(u8, dep.plugin_id),
                .version = try self.allocator.dupe(u8, dep.version_constraint),
            };
            try deps.append(self.allocator, dep_copy);
        }

        return deps.toOwnedSlice();
    }

    /// Download plugin from source
    fn download_plugin(self: *Self, manifest: PluginManifest, version: []const u8) ![]const u8 {
        _ = version;

        // For now, return source path directly
        // In production, this would download from URL
        if (manifest.source_url) |url| {
            return self.allocator.dupe(u8, url);
        }
        return error.NoDownloadURL;
    }

    /// Verify plugin checksum
    fn verify_plugin(self: *Self, plugin_path: []const u8, manifest: PluginManifest) !void {
        _ = self;
        _ = plugin_path;
        _ = manifest;
        // TODO: Implement checksum verification
    }

    /// Validate plugin structure
    fn validate_plugin(self: *Self, plugin_path: []const u8) !ValidatedPlugin {
        _ = self;
        _ = plugin_path;
        // TODO: Implement plugin validation
        return ValidatedPlugin{
            .name = "test",
            .version = "0.1.0",
            .author = "test",
            .description = "test",
            .functions = &.{},
        };
    }
};

/// Plugin registry with metadata storage
pub const PluginRegistry = struct {
    allocator: std.mem.Allocator,
    plugins: std.StringHashMap(PluginManifest),
    registry_path: ?[]const u8,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, registry_path: ?[]const u8) !Self {
        var registry = Self{
            .allocator = allocator,
            .plugins = std.StringHashMap(PluginManifest).init(allocator),
            .registry_path = if (registry_path) |p| try allocator.dupe(u8, p) else null,
        };

        // Load from disk if path provided
        if (registry_path) |path| {
            try registry.load_from_disk(path);
        } else {
            // Load built-in plugins
            try registry.load_builtins();
        }

        return registry;
    }

    pub fn deinit(self: *Self) void {
        var it = self.plugins.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(self.allocator);
        }
        self.plugins.deinit();
        if (self.registry_path) |p| self.allocator.free(p);
    }

    /// Search plugins by query
    pub fn search(self: *Self, allocator: std.mem.Allocator, query: []const u8, options: SearchOptions) ![]PluginManifest {
        var results_list = std.ArrayListUnmanaged(PluginManifest){};

        var it = self.plugins.iterator();
        while (it.next()) |entry| {
            const manifest = entry.value_ptr.*;

            // Check if manifest matches search criteria
            if (try self.matches_query(manifest, query, options)) {
                try results_list.append(allocator, try manifest.clone(allocator));
            }
        }

        return results_list.toOwnedSlice(allocator);
    }

    /// Get plugin manifest by ID
    pub fn get(self: *Self, plugin_id: []const u8) !?PluginManifest {
        if (self.plugins.get(plugin_id)) |manifest| {
            return try manifest.clone(self.allocator);
        }
        return null;
    }

    /// Publish plugin to registry
    pub fn publish(self: *Self, manifest: PluginManifest) !void {
        const id = try self.allocator.dupe(u8, manifest.id);
        errdefer self.allocator.free(id);

        const manifest_copy = try manifest.clone(self.allocator);
        errdefer manifest_copy.deinit(self.allocator);

        try self.plugins.put(id, manifest_copy);

        // Persist to disk if path provided
        if (self.registry_path) |path| {
            try self.save_to_disk(path);
        }
    }

    /// Check if manifest matches search query
    fn matches_query(self: *Self, manifest: PluginManifest, query: []const u8, options: SearchOptions) !bool {
        // Category filter applied first
        if (options.category) |cat| {
            if (!std.mem.eql(u8, manifest.category, cat)) return false;
        }

        // Tags filter
        if (options.tags.len > 0) {
            var has_tag = false;
            for (options.tags) |tag| {
                for (manifest.tags) |plugin_tag| {
                    if (std.mem.eql(u8, plugin_tag, tag)) {
                        has_tag = true;
                        break;
                    }
                }
            }
            if (!has_tag) return false;
        }

        // If query is empty, match all remaining (after filters)
        if (query.len == 0) return true;

        // Simple substring match for now
        // In production, use proper fuzzy matching
        const query_lower = try to_lower(self.allocator, query);
        defer self.allocator.free(query_lower);

        const name_lower = try to_lower(self.allocator, manifest.name);
        defer self.allocator.free(name_lower);

        if (std.mem.indexOf(u8, name_lower, query_lower) != null) return true;

        if (manifest.description) |desc| {
            const desc_lower = try to_lower(self.allocator, desc);
            defer self.allocator.free(desc_lower);
            if (std.mem.indexOf(u8, desc_lower, query_lower) != null) return true;
        }

        return false;
    }

    /// Load plugins from disk
    fn load_from_disk(self: *Self, path: []const u8) !void {
        _ = self;
        _ = path;
        // TODO: Implement loading from JSON file
    }

    /// Save plugins to disk
    fn save_to_disk(self: *Self, path: []const u8) !void {
        _ = self;
        _ = path;
        // TODO: Implement saving to JSON file
    }

    /// Load built-in plugins
    fn load_builtins(self: *Self) !void {
        // Register built-in plugins
        const builtins = [_]PluginManifest{
            .{
                .id = "entity_extractor",
                .name = "Entity Extractor",
                .description = "Extract entities from commit mutations using LLM",
                .author = "NorthstarDB",
                .version = "1.0.0",
                .latest_version = "1.0.0",
                .category = "extraction",
                .tags = &.{ "entity", "ai", "llm" },
                .license = "MIT",
                .homepage = "https://github.com/northstardb",
                .source_url = null,
                .versions = &.{.{
                    .version = "1.0.0",
                    .released_at = 0,
                    .checksum = &[0]u8{},
                    .dependencies = &.{},
                    .min_northstar_version = "0.1.0",
                }},
            },
            .{
                .id = "context_summarizer",
                .name = "Context Summarizer",
                .description = "Prevent context explosion with intelligent summarization",
                .author = "NorthstarDB",
                .version = "1.0.0",
                .latest_version = "1.0.0",
                .category = "optimization",
                .tags = &.{ "context", "ai", "performance" },
                .license = "MIT",
                .homepage = "https://github.com/northstardb",
                .source_url = null,
                .versions = &.{.{
                    .version = "1.0.0",
                    .released_at = 0,
                    .checksum = &[0]u8{},
                    .dependencies = &.{},
                    .min_northstar_version = "0.1.0",
                }},
            },
        };

        for (builtins) |manifest| {
            const manifest_copy = try manifest.clone(self.allocator);
            const id = try self.allocator.dupe(u8, manifest.id);
            try self.plugins.put(id, manifest_copy);
        }
    }
};

/// Local plugin cache
pub const PluginCache = struct {
    allocator: std.mem.Allocator,
    cache_path: []const u8,
    installed: std.StringHashMap(InstalledPluginInfo),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, cache_path: []const u8) !Self {
        const path_copy = try allocator.dupe(u8, cache_path);
        errdefer allocator.free(path_copy);

        var cache = Self{
            .allocator = allocator,
            .cache_path = path_copy,
            .installed = std.StringHashMap(InstalledPluginInfo).init(allocator),
        };

        try cache.load_installed();

        return cache;
    }

    pub fn deinit(self: *Self) void {
        var it = self.installed.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(self.allocator);
        }
        self.installed.deinit();
        self.allocator.free(self.cache_path);
    }

    /// Check if plugin is installed
    pub fn is_installed(self: *Self, plugin_id: []const u8, version: []const u8) !bool {
        if (self.installed.get(plugin_id)) |info| {
            return std.mem.eql(u8, info.version, version);
        }
        return false;
    }

    /// Get plugin installation path
    pub fn get_plugin_path(self: *Self, plugin_id: []const u8, version: []const u8) ![]const u8 {
        const info = (self.installed.get(plugin_id)) orelse return error.NotInstalled;
        if (!std.mem.eql(u8, info.version, version)) return error.VersionMismatch;
        return self.allocator.dupe(u8, info.install_path);
    }

    /// Get installed version
    pub fn get_installed_version(self: *Self, plugin_id: []const u8) !?[]const u8 {
        if (self.installed.get(plugin_id)) |info| {
            return try self.allocator.dupe(u8, info.version);
        }
        return null;
    }

    /// Install plugin to cache
    pub fn install(self: *Self, plugin_id: []const u8, version: []const u8, source_path: []const u8) !void {
        _ = source_path;

        // Create install directory
        const install_dir = try std.fmt.allocPrint(
            self.allocator,
            "{s}/{s}/{s}",
            .{ self.cache_path, plugin_id, version }
        );
        defer self.allocator.free(install_dir);

        try std.fs.cwd().makePath(install_dir);

        // Copy plugin files
        const plugin_file = try std.fmt.allocPrint(
            self.allocator,
            "{s}/plugin.zig",
            .{install_dir}
        );
        defer self.allocator.free(plugin_file);

        // For now, just create a placeholder
        // In production, copy actual plugin files
        _ = try std.fs.cwd().createFile(plugin_file, .{});

        // Record installation
        const id_copy = try self.allocator.dupe(u8, plugin_id);
        errdefer self.allocator.free(id_copy);

        const info = InstalledPluginInfo{
            .version = try self.allocator.dupe(u8, version),
            .install_path = try self.allocator.dupe(u8, install_dir),
            .installed_at = std.time.timestamp(),
        };

        try self.installed.put(id_copy, info);
        try self.save_installed();
    }

    /// Uninstall plugin
    pub fn uninstall(self: *Self, plugin_id: []const u8, version: []const u8) !void {
        const entry = self.installed.fetchRemove(plugin_id) orelse return error.NotInstalled;
        const info = entry.value;

        if (!std.mem.eql(u8, info.version, version)) {
            // Put it back - create a new key since the old one was moved
            const key_copy = self.allocator.dupe(u8, plugin_id) catch {
                // Can't restore, just return error
                cleanupInstalledPluginInfo(&info, self.allocator);
                return error.OutOfMemory;
            };
            try self.installed.put(key_copy, info);
            return error.VersionMismatch;
        }

        // Remove files
        std.fs.cwd().deleteTree(info.install_path) catch {};

        // Clean up memory - entry.key is owned by the hashmap
        self.allocator.free(entry.key);
        cleanupInstalledPluginInfo(&info, self.allocator);

        try self.save_installed();
    }

    /// List installed plugins
    pub fn list_installed(self: *Self, allocator: std.mem.Allocator) ![]InstalledPlugin {
        var results_list = std.ArrayListUnmanaged(InstalledPlugin){};

        var it = self.installed.iterator();
        while (it.next()) |entry| {
            const info = entry.value_ptr.*;
            try results_list.append(allocator, InstalledPlugin{
                .plugin_id = try allocator.dupe(u8, entry.key_ptr.*),
                .version = try allocator.dupe(u8, info.version),
                .install_path = try allocator.dupe(u8, info.install_path),
                .installed_at = info.installed_at,
            });
        }

        return results_list.toOwnedSlice(allocator);
    }

    /// Load installed plugins from registry
    fn load_installed(self: *Self) !void {
        const registry_path = try std.fmt.allocPrint(
            self.allocator,
            "{s}/installed.json",
            .{self.cache_path}
        );
        defer self.allocator.free(registry_path);

        const file = std.fs.cwd().openFile(registry_path, .{}) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        defer file.close();

        // TODO: Parse JSON registry
    }

    /// Save installed plugins to registry
    fn save_installed(self: *Self) !void {
        const registry_path = try std.fmt.allocPrint(
            self.allocator,
            "{s}/installed.json",
            .{self.cache_path}
        );
        defer self.allocator.free(registry_path);

        // TODO: Write JSON registry
    }
};

/// Plugin manifest with metadata
pub const PluginManifest = struct {
    id: []const u8,
    name: []const u8,
    description: ?[]const u8,
    author: []const u8,
    version: []const u8,
    latest_version: []const u8,
    category: []const u8,
    tags: []const []const u8,
    license: []const u8,
    homepage: ?[]const u8,
    source_url: ?[]const u8,
    versions: []const VersionInfo,

    pub fn deinit(self: *PluginManifest, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.name);
        if (self.description) |d| allocator.free(d);
        allocator.free(self.author);
        allocator.free(self.version);
        allocator.free(self.latest_version);
        allocator.free(self.category);
        for (self.tags) |t| allocator.free(t);
        allocator.free(self.tags);
        allocator.free(self.license);
        if (self.homepage) |h| allocator.free(h);
        if (self.source_url) |s| allocator.free(s);
        // versions is static for now
    }

    pub fn clone(self: *const PluginManifest, allocator: std.mem.Allocator) !PluginManifest {
        const tags = try allocator.alloc([]const u8, self.tags.len);
        for (self.tags, 0..) |tag, i| {
            tags[i] = try allocator.dupe(u8, tag);
        }
        errdefer {
            for (tags) |t| allocator.free(t);
            allocator.free(tags);
        }

        return PluginManifest{
            .id = try allocator.dupe(u8, self.id),
            .name = try allocator.dupe(u8, self.name),
            .description = if (self.description) |d| try allocator.dupe(u8, d) else null,
            .author = try allocator.dupe(u8, self.author),
            .version = try allocator.dupe(u8, self.version),
            .latest_version = try allocator.dupe(u8, self.latest_version),
            .category = try allocator.dupe(u8, self.category),
            .tags = tags,
            .license = try allocator.dupe(u8, self.license),
            .homepage = if (self.homepage) |h| try allocator.dupe(u8, h) else null,
            .source_url = if (self.source_url) |s| try allocator.dupe(u8, s) else null,
            .versions = self.versions,
        };
    }

    pub fn getVersionInfo(self: *const PluginManifest, version: []const u8) ?VersionInfo {
        for (self.versions) |v| {
            if (std.mem.eql(u8, v.version, version)) return v;
        }
        return null;
    }

    pub fn from_metadata(allocator: std.mem.Allocator, metadata: PublishMetadata, plugin: ValidatedPlugin) !PluginManifest {
        _ = plugin;

        const version_info = [_]VersionInfo{.{
            .version = metadata.version,
            .released_at = std.time.timestamp(),
            .checksum = &[0]u8{},
            .dependencies = &.{},
            .min_northstar_version = metadata.min_northstar_version orelse "0.1.0",
        }};

        return PluginManifest{
            .id = try allocator.dupe(u8, metadata.id),
            .name = try allocator.dupe(u8, metadata.name),
            .description = if (metadata.description) |d| try allocator.dupe(u8, d) else null,
            .author = try allocator.dupe(u8, metadata.author),
            .version = try allocator.dupe(u8, metadata.version),
            .latest_version = try allocator.dupe(u8, metadata.version),
            .category = try allocator.dupe(u8, metadata.category),
            .tags = metadata.tags,
            .license = try allocator.dupe(u8, metadata.license),
            .homepage = if (metadata.homepage) |h| try allocator.dupe(u8, h) else null,
            .source_url = if (metadata.source_url) |s| try allocator.dupe(u8, s) else null,
            .versions = &version_info,
        };
    }
};

/// Version information
pub const VersionInfo = struct {
    version: []const u8,
    released_at: i64,
    checksum: []const u8,
    dependencies: []const Dependency,
    min_northstar_version: []const u8,
};

/// Dependency specification
pub const Dependency = struct {
    plugin_id: []const u8,
    version_constraint: []const u8,
};

/// Installed plugin info
pub const InstalledPluginInfo = struct {
    version: []const u8,
    install_path: []const u8,
    installed_at: i64,

    pub fn deinit(self: *InstalledPluginInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.version);
        allocator.free(self.install_path);
    }
};

// Helper to cast away const for cleanup
fn cleanupInstalledPluginInfo(info: *const InstalledPluginInfo, allocator: std.mem.Allocator) void {
    @constCast(info).deinit(allocator);
}

/// Installed plugin representation
pub const InstalledPlugin = struct {
    plugin_id: []const u8,
    version: []const u8,
    install_path: []const u8,
    installed_at: i64,
};

/// Marketplace configuration
pub const MarketplaceConfig = struct {
    registry_path: ?[]const u8 = null,
    cache_path: []const u8,
    download_timeout_ms: u64 = 30000,
    max_retries: u32 = 3,
};

/// Search options
pub const SearchOptions = struct {
    category: ?[]const u8 = null,
    tags: []const []const u8 = &.{},
    limit: usize = 50,
    offset: usize = 0,
};

/// Install result
pub const InstallResult = struct {
    status: InstallStatus,
    plugin_path: []const u8,

    pub fn deinit(self: *InstallResult, allocator: std.mem.Allocator) void {
        allocator.free(self.plugin_path);
    }
};

pub const InstallStatus = enum {
    success,
    already_installed,
    dependency_failed,
    download_failed,
    verification_failed,
};

/// Update result
pub const UpdateResult = struct {
    status: UpdateStatus,
    current_version: []const u8,
    previous_version: ?[]const u8 = null,
    plugin_path: []const u8 = "",

    pub fn deinit(self: *UpdateResult, allocator: std.mem.Allocator) void {
        allocator.free(self.current_version);
        if (self.previous_version) |v| allocator.free(v);
        if (self.plugin_path.len > 0) allocator.free(self.plugin_path);
    }
};

pub const UpdateStatus = enum {
    updated,
    up_to_date,
    not_installed,
    dependency_failed,
};

/// Publish result
pub const PublishResult = struct {
    plugin_id: []const u8,
    version: []const u8,
    status: PublishStatus,

    pub fn deinit(self: *PublishResult, allocator: std.mem.Allocator) void {
        allocator.free(self.plugin_id);
        allocator.free(self.version);
    }
};

pub const PublishStatus = enum {
    published,
    validation_failed,
    already_exists,
};

/// Publish metadata
pub const PublishMetadata = struct {
    id: []const u8,
    name: []const u8,
    description: ?[]const u8 = null,
    author: []const u8,
    version: []const u8,
    category: []const u8,
    tags: []const []const u8 = &.{},
    license: []const u8 = "MIT",
    homepage: ?[]const u8 = null,
    source_url: ?[]const u8 = null,
    min_northstar_version: ?[]const u8 = null,
};

/// Validated plugin
pub const ValidatedPlugin = struct {
    name: []const u8,
    version: []const u8,
    author: []const u8,
    description: []const u8,
    functions: []const []const u8,

    pub fn deinit(self: *ValidatedPlugin, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.version);
        allocator.free(self.author);
        allocator.free(self.description);
        for (self.functions) |f| allocator.free(f);
        allocator.free(self.functions);
    }
};

/// Helper function to convert string to lowercase
fn to_lower(allocator: std.mem.Allocator, str: []const u8) ![]const u8 {
    const result = try allocator.alloc(u8, str.len);
    for (str, 0..) |c, i| {
        result[i] = if (c >= 'A' and c <= 'Z') c + 32 else c;
    }
    return result;
}

// ============================================================================
// Tests
// ============================================================================

test "marketplace_initialization" {
    const config = MarketplaceConfig{
        .registry_path = null,
        .cache_path = "/tmp/test_marketplace",
    };

    var marketplace = try PluginMarketplace.init(std.testing.allocator, config);
    defer marketplace.deinit();

    try std.testing.expectEqual(@as(usize, 2), marketplace.registry.plugins.count());
}

test "search_plugins" {
    const config = MarketplaceConfig{
        .registry_path = null,
        .cache_path = "/tmp/test_marketplace",
    };

    var marketplace = try PluginMarketplace.init(std.testing.allocator, config);
    defer marketplace.deinit();

    const options = SearchOptions{};
    const results = try marketplace.search("entity", options);
    defer {
        for (results) |*r| r.deinit(std.testing.allocator);
        std.testing.allocator.free(results);
    }

    try std.testing.expect(results.len >= 1);
}

test "get_plugin_manifest" {
    const config = MarketplaceConfig{
        .registry_path = null,
        .cache_path = "/tmp/test_marketplace",
    };

    var marketplace = try PluginMarketplace.init(std.testing.allocator, config);
    defer marketplace.deinit();

    var manifest = try marketplace.get_manifest("entity_extractor");
    defer if (manifest) |*m| m.deinit(std.testing.allocator);

    try std.testing.expect(manifest != null);
    if (manifest) |m| {
        try std.testing.expectEqualStrings("entity_extractor", m.id);
        try std.testing.expectEqualStrings("Entity Extractor", m.name);
    }
}

test "plugin_not_found" {
    const config = MarketplaceConfig{
        .registry_path = null,
        .cache_path = "/tmp/test_marketplace",
    };

    var marketplace = try PluginMarketplace.init(std.testing.allocator, config);
    defer marketplace.deinit();

    const manifest = try marketplace.get_manifest("nonexistent_plugin");
    try std.testing.expect(manifest == null);
}

test "search_with_category_filter" {
    const config = MarketplaceConfig{
        .registry_path = null,
        .cache_path = "/tmp/test_marketplace",
    };

    var marketplace = try PluginMarketplace.init(std.testing.allocator, config);
    defer marketplace.deinit();

    const options = SearchOptions{
        .category = "extraction",
    };

    const results = try marketplace.search("", options);
    defer {
        for (results) |*r| r.deinit(std.testing.allocator);
        std.testing.allocator.free(results);
    }

    for (results) |r| {
        try std.testing.expectEqualStrings("extraction", r.category);
    }
}

test "search_with_tag_filter" {
    const config = MarketplaceConfig{
        .registry_path = null,
        .cache_path = "/tmp/test_marketplace",
    };

    var marketplace = try PluginMarketplace.init(std.testing.allocator, config);
    defer marketplace.deinit();

    const options = SearchOptions{
        .tags = &.{ "ai" },
    };

    const results = try marketplace.search("", options);
    defer {
        for (results) |*r| r.deinit(std.testing.allocator);
        std.testing.allocator.free(results);
    }

    // Should find plugins with "ai" tag
    try std.testing.expect(results.len >= 2);
}

test "manifest_clone" {
    const versions = [_]VersionInfo{.{
        .version = "1.0.0",
        .released_at = 0,
        .checksum = &[0]u8{},
        .dependencies = &.{},
        .min_northstar_version = "0.1.0",
    }};

    const tags = try std.testing.allocator.alloc([]const u8, 2);
    tags[0] = try std.testing.allocator.dupe(u8, "tag1");
    tags[1] = try std.testing.allocator.dupe(u8, "tag2");

    const original = PluginManifest{
        .id = "test_id",
        .name = "Test Plugin",
        .description = "A test plugin",
        .author = "Test Author",
        .version = "1.0.0",
        .latest_version = "1.0.0",
        .category = "test",
        .tags = tags,
        .license = "MIT",
        .homepage = "https://example.com",
        .source_url = "https://example.com/plugin.zip",
        .versions = &versions,
    };

    var cloned = try original.clone(std.testing.allocator);
    defer cloned.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings(original.id, cloned.id);
    try std.testing.expectEqualStrings(original.name, cloned.name);
    try std.testing.expectEqualStrings(original.description.?, cloned.description.?);
    try std.testing.expectEqual(@as(usize, 2), cloned.tags.len);

    // Clean up original manifest's tags
    for (tags) |t| std.testing.allocator.free(t);
    std.testing.allocator.free(tags);
}

test "get_version_info" {
    const dep = Dependency{
        .plugin_id = "dep_plugin",
        .version_constraint = ">=1.0.0",
    };

    const versions = [_]VersionInfo{
        .{
            .version = "1.0.0",
            .released_at = 1000,
            .checksum = &[0]u8{},
            .dependencies = &.{dep},
            .min_northstar_version = "0.1.0",
        },
        .{
            .version = "2.0.0",
            .released_at = 2000,
            .checksum = &[0]u8{},
            .dependencies = &.{},
            .min_northstar_version = "0.2.0",
        },
    };

    const manifest = PluginManifest{
        .id = "test",
        .name = "Test",
        .description = null,
        .author = "Test",
        .version = "2.0.0",
        .latest_version = "2.0.0",
        .category = "test",
        .tags = &.{},
        .license = "MIT",
        .homepage = null,
        .source_url = null,
        .versions = &versions,
    };

    const v1 = manifest.getVersionInfo("1.0.0");
    try std.testing.expect(v1 != null);
    try std.testing.expectEqual(@as(usize, 1), v1.?.dependencies.len);

    const v2 = manifest.getVersionInfo("2.0.0");
    try std.testing.expect(v2 != null);
    try std.testing.expectEqual(@as(usize, 0), v2.?.dependencies.len);

    const v3 = manifest.getVersionInfo("3.0.0");
    try std.testing.expect(v3 == null);
}

test "cache_install_uninstall" {
    // Create temp cache directory
    const cache_dir = "/tmp/test_plugin_cache";

    // Clean up any existing test cache
    std.fs.cwd().deleteTree(cache_dir) catch {};

    defer std.fs.cwd().deleteTree(cache_dir) catch {};

    var cache = try PluginCache.init(std.testing.allocator, cache_dir);
    defer cache.deinit();

    // Install plugin
    try cache.install("test_plugin", "1.0.0", "/fake/source");

    // Check installed
    const is_installed = try cache.is_installed("test_plugin", "1.0.0");
    try std.testing.expect(is_installed);

    // Get version
    const version = try cache.get_installed_version("test_plugin");
    try std.testing.expect(version != null);
    if (version) |v| {
        try std.testing.expectEqualStrings("1.0.0", v);
        std.testing.allocator.free(v);
    }

    // List installed
    const installed = try cache.list_installed(std.testing.allocator);
    defer {
        for (installed) |*i| {
            std.testing.allocator.free(i.plugin_id);
            std.testing.allocator.free(i.version);
            std.testing.allocator.free(i.install_path);
        }
        std.testing.allocator.free(installed);
    }
    try std.testing.expectEqual(@as(usize, 1), installed.len);

    // Uninstall
    try cache.uninstall("test_plugin", "1.0.0");

    // Check uninstalled
    const is_still_installed = try cache.is_installed("test_plugin", "1.0.0");
    try std.testing.expect(!is_still_installed);
}

test "registry_builtins" {
    var registry = try PluginRegistry.init(std.testing.allocator, null);
    defer registry.deinit();

    try std.testing.expectEqual(@as(usize, 2), registry.plugins.count());

    // Entity extractor should be present
    var entity_extractor = try registry.get("entity_extractor");
    defer if (entity_extractor) |*m| m.deinit(std.testing.allocator);

    try std.testing.expect(entity_extractor != null);
    if (entity_extractor) |m| {
        try std.testing.expectEqualStrings("entity_extractor", m.id);
        try std.testing.expectEqualStrings("extraction", m.category);
    }

    // Context summarizer should be present
    var context_summarizer = try registry.get("context_summarizer");
    defer if (context_summarizer) |*m| m.deinit(std.testing.allocator);

    try std.testing.expect(context_summarizer != null);
    if (context_summarizer) |m| {
        try std.testing.expectEqualStrings("context_summarizer", m.id);
        try std.testing.expectEqualStrings("optimization", m.category);
    }
}
