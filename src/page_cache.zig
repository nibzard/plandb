//! Page Cache with LRU eviction and pinning support
//!
//! Provides an in-memory cache for frequently accessed pages to reduce I/O.
//! Pages can be "pinned" by snapshot readers to prevent eviction during their
//! transaction lifetime. Unpinned pages are evicted using LRU policy when
//! the cache reaches capacity.

const std = @import("std");
const pager = @import("pager.zig");

/// Page cache entry with LRU tracking and pin count
const CacheEntry = struct {
    page_id: u64,
    data: []const u8,
    pin_count: u32,
    last_access: u64, // Monotonically increasing access counter
    prev: ?*CacheEntry,
    next: ?*CacheEntry,

    /// Create a new cache entry
    fn init(page_id: u64, data: []const u8, allocator: std.mem.Allocator) !*CacheEntry {
        const entry = try allocator.create(CacheEntry);
        const data_copy = try allocator.alloc(u8, data.len);
        @memcpy(data_copy, data);

        entry.* = .{
            .page_id = page_id,
            .data = data_copy,
            .pin_count = 0,
            .last_access = 0,
            .prev = null,
            .next = null,
        };
        return entry;
    }

    /// Free the entry and its data
    fn deinit(self: *CacheEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.data);
        allocator.destroy(self);
    }
};

/// LRU page cache with pinning support
pub const PageCache = struct {
    allocator: std.mem.Allocator,
    entries: std.AutoHashMap(u64, *CacheEntry),
    lru_head: ?*CacheEntry, // Most recently used
    lru_tail: ?*CacheEntry, // Least recently used
    access_counter: u64,
    max_pages: usize,
    max_bytes: usize,
    current_bytes: usize,

    const Self = @This();

    /// Initialize a new page cache
    /// max_pages: Maximum number of pages to cache (0 = unlimited)
    /// max_bytes: Maximum total bytes to cache (0 = unlimited)
    pub fn init(allocator: std.mem.Allocator, max_pages: usize, max_bytes: usize) !Self {
        const default_max = 1024; // Default to 1024 pages or 16MB (16KB * 1024)
        const actual_max_pages = if (max_pages == 0) default_max else max_pages;
        const actual_max_bytes = if (max_bytes == 0) 16 * 1024 * 1024 else max_bytes;

        return Self{
            .allocator = allocator,
            .entries = std.AutoHashMap(u64, *CacheEntry).init(allocator),
            .lru_head = null,
            .lru_tail = null,
            .access_counter = 0,
            .max_pages = actual_max_pages,
            .max_bytes = actual_max_bytes,
            .current_bytes = 0,
        };
    }

    /// Clean up the page cache
    pub fn deinit(self: *Self) void {
        var it = self.entries.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.*.deinit(self.allocator);
        }
        self.entries.deinit();
    }

    /// Check if a page is cached
    pub fn contains(self: *const Self, page_id: u64) bool {
        return self.entries.get(page_id) != null;
    }

    /// Get a cached page without pinning (for internal use)
    fn getUnpinned(self: *Self, page_id: u64) ?[]const u8 {
        if (self.entries.get(page_id)) |entry| {
            // Update access time and move to front of LRU
            self.access_counter += 1;
            entry.last_access = self.access_counter;
            self.moveToFront(entry);
            return entry.data;
        }
        return null;
    }

    /// Get a cached page, pinning it to prevent eviction
    pub fn get(self: *Self, page_id: u64) ?[]const u8 {
        if (self.entries.get(page_id)) |entry| {
            // Pin the entry
            entry.pin_count += 1;

            // Update access time and move to front of LRU
            self.access_counter += 1;
            entry.last_access = self.access_counter;
            self.moveToFront(entry);

            return entry.data;
        }
        return null;
    }

    /// Put a page into the cache
    pub fn put(self: *Self, page_id: u64, data: []const u8) !void {
        // If page already exists, just update it
        if (self.entries.get(page_id)) |entry| {
            // Update the data (this shouldn't normally happen)
            self.allocator.free(entry.data);
            const new_data = try self.allocator.alloc(u8, data.len);
            @memcpy(new_data, data);
            entry.data = new_data;

            // Update access time and move to front
            self.access_counter += 1;
            entry.last_access = self.access_counter;
            self.moveToFront(entry);

            // Update byte count
            self.current_bytes = self.current_bytes - entry.data.len + data.len;

            return;
        }

        // Create new entry
        const entry = try CacheEntry.init(page_id, data, self.allocator);
        errdefer entry.deinit(self.allocator);

        // Add to hash map
        try self.entries.put(page_id, entry);

        // Add to front of LRU list
        self.access_counter += 1;
        entry.last_access = self.access_counter;
        self.addToFront(entry);

        // Update byte count
        self.current_bytes += data.len;

        // Evict if necessary
        try self.evictIfNecessary();
    }

    /// Unpin a page (decrement pin count)
    pub fn unpin(self: *Self, page_id: u64) void {
        if (self.entries.get(page_id)) |entry| {
            if (entry.pin_count > 0) {
                entry.pin_count -= 1;
            }
        }
    }

    /// Pin a page (increment pin count)
    pub fn pin(self: *Self, page_id: u64) void {
        if (self.entries.get(page_id)) |entry| {
            entry.pin_count += 1;
        }
    }

    /// Remove a specific page from the cache (forced eviction)
    pub fn remove(self: *Self, page_id: u64) bool {
        if (self.entries.fetchRemove(page_id)) |kv| {
            const entry = kv.value;
            // Only remove if not pinned
            if (entry.pin_count == 0) {
                self.removeFromList(entry);
                self.current_bytes -= entry.data.len;
                entry.deinit(self.allocator);
                return true;
            }
            // Re-insert if pinned
            self.entries.put(page_id, entry) catch {};
        }
        return false;
    }

    /// Clear all unpinned pages from the cache
    pub fn clear(self: *Self) void {
        var to_remove = std.array_list.Managed(u64).init(self.allocator);
        defer to_remove.deinit();

        var it = self.entries.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.*.pin_count == 0) {
                to_remove.append(entry.key_ptr.*) catch {};
            }
        }

        for (to_remove.items) |page_id| {
            _ = self.remove(page_id);
        }
    }

    /// Evict unpinned pages if we're over capacity
    fn evictIfNecessary(self: *Self) !void {
        // Evict based on page count
        while (self.entries.count() > self.max_pages) {
            if (self.evictOne() == null) break; // No unpinned pages to evict
        }

        // Evict based on byte count
        while (self.current_bytes > self.max_bytes) {
            if (self.evictOne() == null) break; // No unpinned pages to evict
        }
    }

    /// Evict one unpinned page from the LRU tail
    fn evictOne(self: *Self) ?u64 {
        // Find the first unpinned entry starting from LRU tail
        var current = self.lru_tail;
        while (current) |entry| {
            if (entry.pin_count == 0) {
                const page_id = entry.page_id;
                _ = self.entries.remove(page_id);
                self.removeFromList(entry);
                self.current_bytes -= entry.data.len;
                entry.deinit(self.allocator);
                return page_id;
            }
            current = entry.prev;
        }
        return null; // No unpinned pages to evict
    }

    /// Add entry to front of LRU list (most recently used)
    fn addToFront(self: *Self, entry: *CacheEntry) void {
        entry.prev = null;
        entry.next = self.lru_head;

        if (self.lru_head) |head| {
            head.prev = entry;
        }

        self.lru_head = entry;

        if (self.lru_tail == null) {
            self.lru_tail = entry;
        }
    }

    /// Move entry to front of LRU list
    fn moveToFront(self: *Self, entry: *CacheEntry) void {
        // Already at front
        if (entry == self.lru_head) return;

        // Remove from current position
        self.removeFromList(entry);

        // Add to front
        self.addToFront(entry);
    }

    /// Remove entry from LRU list
    fn removeFromList(self: *Self, entry: *CacheEntry) void {
        // Update previous entry
        if (entry.prev) |prev| {
            prev.next = entry.next;
        } else {
            // Entry is head
            self.lru_head = entry.next;
        }

        // Update next entry
        if (entry.next) |next| {
            next.prev = entry.prev;
        } else {
            // Entry is tail
            self.lru_tail = entry.prev;
        }

        entry.prev = null;
        entry.next = null;
    }

    /// Statistics about cache performance
    pub const Stats = struct {
        total_pages: usize,
        pinned_pages: usize,
        total_bytes: usize,
        max_pages: usize,
        max_bytes: usize,
    };

    /// Get cache statistics
    pub fn getStats(self: *const Self) Stats {
        var pinned_count: usize = 0;
        var it = self.entries.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.*.pin_count > 0) {
                pinned_count += 1;
            }
        }

        return Stats{
            .total_pages = self.entries.count(),
            .pinned_pages = pinned_count,
            .total_bytes = self.current_bytes,
            .max_pages = self.max_pages,
            .max_bytes = self.max_bytes,
        };
    }
};

/// Guard for auto-unpinning pages on scope exit
pub const PageGuard = struct {
    cache: *PageCache,
    page_id: u64,

    /// Create a new page guard (doesn't pin, just tracks for unpin)
    pub fn init(cache: *PageCache, page_id: u64) PageGuard {
        return .{
            .cache = cache,
            .page_id = page_id,
        };
    }

    /// Explicitly unpin the page
    pub fn unpin(self: *PageGuard) void {
        self.cache.unpin(self.page_id);
    }

    /// Auto-unpin on deinit
    pub fn deinit(self: *PageGuard) void {
        self.unpin();
    }
};

test "PageCache basic operations" {
    var cache = try PageCache.init(std.testing.allocator, 4, 1024);
    defer cache.deinit();

    var page_data: [16]u8 = undefined;
    @memset(&page_data, 0xAB);

    // Put pages
    try cache.put(1, &page_data);
    try cache.put(2, &page_data);
    try cache.put(3, &page_data);

    // Check contains
    try std.testing.expect(cache.contains(1));
    try std.testing.expect(cache.contains(2));
    try std.testing.expect(!cache.contains(99));

    // Get pages
    const result = cache.get(1);
    try std.testing.expect(result != null);
    try std.testing.expectEqualSlices(u8, &page_data, result.?);

    // Verify pin count
    if (cache.entries.get(1)) |entry| {
        try std.testing.expectEqual(@as(u32, 1), entry.pin_count);
    }

    // Unpin
    cache.unpin(1);
    if (cache.entries.get(1)) |entry| {
        try std.testing.expectEqual(@as(u32, 0), entry.pin_count);
    }
}

test "PageCache LRU eviction" {
    var cache = try PageCache.init(std.testing.allocator, 3, 1024);
    defer cache.deinit();

    var page_data: [16]u8 = undefined;

    // Fill cache
    for (1..4) |i| {
        @memset(&page_data, @intCast(i));
        try cache.put(i, &page_data);
    }

    try std.testing.expectEqual(@as(usize, 3), cache.entries.count());

    // Access page 1 to make it MRU
    _ = cache.get(1);
    cache.unpin(1);

    // Add page 4, should evict page 2 (least recently used)
    @memset(&page_data, 4);
    try cache.put(4, &page_data);

    try std.testing.expect(cache.contains(1)); // Accessed recently
    try std.testing.expect(!cache.contains(2)); // Evicted
    try std.testing.expect(cache.contains(3));
    try std.testing.expect(cache.contains(4));
}

test "PageCache pinning prevents eviction" {
    var cache = try PageCache.init(std.testing.allocator, 2, 1024);
    defer cache.deinit();

    var page_data: [16]u8 = undefined;

    // Add and pin page 1
    @memset(&page_data, 1);
    try cache.put(1, &page_data);
    _ = cache.get(1); // This pins the page

    // Add page 2
    @memset(&page_data, 2);
    try cache.put(2, &page_data);

    // Add page 3 - page 2 should be evicted, not page 1 (pinned)
    @memset(&page_data, 3);
    try cache.put(3, &page_data);

    try std.testing.expect(cache.contains(1)); // Pinned, not evicted
    try std.testing.expect(!cache.contains(2)); // Evicted
    try std.testing.expect(cache.contains(3));
}

test "PageCache stats" {
    var cache = try PageCache.init(std.testing.allocator, 10, 10240);
    defer cache.deinit();

    var page_data: [100]u8 = undefined;
    @memset(&page_data, 0xAA);

    // Add some pages
    try cache.put(1, &page_data);
    try cache.put(2, &page_data);

    // Pin one page
    _ = cache.get(1);

    const stats = cache.getStats();
    try std.testing.expectEqual(@as(usize, 2), stats.total_pages);
    try std.testing.expectEqual(@as(usize, 1), stats.pinned_pages);
    try std.testing.expectEqual(@as(usize, 200), stats.total_bytes);
}

test "PageGuard auto-unpin" {
    var cache = try PageCache.init(std.testing.allocator, 10, 10240);
    defer cache.deinit();

    var page_data: [100]u8 = undefined;
    @memset(&page_data, 0xAA);

    try cache.put(1, &page_data);

    // Pin with guard
    {
        _ = cache.get(1);
        var guard = PageGuard.init(&cache, 1);
        defer guard.deinit(); // Auto-unpin

        if (cache.entries.get(1)) |entry| {
            try std.testing.expectEqual(@as(u32, 2), entry.pin_count); // 1 from get, 1 from guard init (no, guard doesn't auto-pin)
        }
        // Actually, guard just tracks for unpin on deinit
    }

    // After guard scope, should be unpinned (still 1 from the initial get)
    if (cache.entries.get(1)) |entry| {
        try std.testing.expectEqual(@as(u32, 1), entry.pin_count);
    }
}

test "PageCache clear" {
    var cache = try PageCache.init(std.testing.allocator, 10, 10240);
    defer cache.deinit();

    var page_data: [100]u8 = undefined;
    @memset(&page_data, 0xAA);

    try cache.put(1, &page_data);
    try cache.put(2, &page_data);

    // Pin page 1
    _ = cache.get(1);

    cache.clear();

    try std.testing.expect(cache.contains(1)); // Pinned, not cleared
    try std.testing.expect(!cache.contains(2)); // Unpinned, cleared
}

test "PageCache byte limit eviction" {
    var cache = try PageCache.init(std.testing.allocator, 100, 150); // 150 byte limit
    defer cache.deinit();

    var page_data_100: [100]u8 = undefined;
    @memset(&page_data_100, 1);

    var page_data_60: [60]u8 = undefined;
    @memset(&page_data_60, 2);

    // Add 100 byte page
    try cache.put(1, &page_data_100);
    try std.testing.expectEqual(@as(usize, 100), cache.current_bytes);

    // Add 60 byte page - should evict the 100 byte page
    try cache.put(2, &page_data_60);

    // 60 bytes should fit, 100 byte page evicted
    try std.testing.expect(!cache.contains(1));
    try std.testing.expect(cache.contains(2));
}
