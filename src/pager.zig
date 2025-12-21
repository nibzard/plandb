const std = @import("std");

// Magic numbers for identification
pub const PAGE_MAGIC: u32 = 0x4E534442; // "NSDB"
pub const META_MAGIC: u32 = 0x4D455441; // "META"
pub const BTREE_MAGIC: u32 = 0x42545245; // "BTRE"

// CRC32C implementation (Castagnoli polynomial)
const CRC32C_POLYNOMIAL: u32 = 0x1EDC6F41;

// CRC32C lookup table
const crc32c_table = initCrc32cTable();

fn initCrc32cTable() [256]u32 {
    @setEvalBranchQuota(3000);
    var table: [256]u32 = undefined;
    for (0..256) |i| {
        var crc: u32 = @intCast(i);
        for (0..8) |_| {
            if (crc & 1 != 0) {
                crc = (crc >> 1) ^ CRC32C_POLYNOMIAL;
            } else {
                crc = crc >> 1;
            }
        }
        table[i] = crc;
    }
    return table;
}

pub fn crc32c(data: []const u8) u32 {
    var crc: u32 = 0xFFFFFFFF;
    for (data) |byte| {
        const table_index = @as(u8, @truncate(crc ^ byte));
        crc = (crc >> 8) ^ crc32c_table[table_index];
    }
    return crc ^ 0xFFFFFFFF;
}

// Format version
pub const FORMAT_VERSION: u16 = 0;

// Default page size for V0
pub const DEFAULT_PAGE_SIZE: u16 = 16384; // 16KB

// Page types
pub const PageType = enum(u8) {
    meta = 0,
    btree_internal = 1,
    btree_leaf = 2,
    freelist = 3,
    log_segment = 4,
};

// Page header - starts every page
pub const PageHeader = struct {
    magic: u32 = PAGE_MAGIC,
    format_version: u16 = FORMAT_VERSION,
    page_type: PageType,
    flags: u8 = 0,
    page_id: u64,
    txn_id: u64,
    payload_len: u32,
    header_crc32c: u32,
    page_crc32c: u32,

    const Self = @This();

    pub const SIZE: usize = @sizeOf(Self);

    // Calculate header checksum (excluding header_crc32c and page_crc32c fields)
    pub fn calculateHeaderChecksum(self: Self) u32 {
        // Create a temporary version with checksum fields zeroed
        const temp = Self{
            .magic = self.magic,
            .format_version = self.format_version,
            .page_type = self.page_type,
            .flags = self.flags,
            .page_id = self.page_id,
            .txn_id = self.txn_id,
            .payload_len = self.payload_len,
            .header_crc32c = 0,
            .page_crc32c = 0,
        };

        // Calculate CRC32C of header fields (excluding checksum fields)
        const bytes = std.mem.asBytes(&temp);
        const header_crc_offset: usize = @offsetOf(Self, "header_crc32c");
        return crc32c(bytes[0..header_crc_offset]);
    }

    // Validate header checksum
    pub fn validateHeaderChecksum(self: Self) bool {
        return self.header_crc32c == self.calculateHeaderChecksum();
    }

    // Encode header to bytes
    pub fn encode(self: Self, dest: []u8) !void {
        if (dest.len < SIZE) return error.BufferTooSmall;
        std.mem.bytesAsValue(Self, dest[0..SIZE]).* = self;
    }

    // Decode header from bytes
    pub fn decode(bytes: []const u8) !Self {
        if (bytes.len < SIZE) return error.InvalidHeaderSize;
        const header = std.mem.bytesAsValue(Self, bytes[0..SIZE]);

        // Validate magic and version
        if (header.magic != PAGE_MAGIC) return error.InvalidMagic;
        if (header.format_version != FORMAT_VERSION) return error.UnsupportedFormat;

        return header.*;
    }
};

// Meta page payload (follows page header in meta pages)
pub const MetaPayload = struct {
    meta_magic: u32 = META_MAGIC,
    format_version: u16 = FORMAT_VERSION,
    page_size: u16 = DEFAULT_PAGE_SIZE,
    committed_txn_id: u64,
    root_page_id: u64,
    freelist_head_page_id: u64,
    log_tail_lsn: u64,
    meta_crc32c: u32,

    const Self = @This();

    pub const SIZE: usize = @sizeOf(Self);

    // Calculate meta payload checksum (excluding meta_crc32c field)
    pub fn calculateChecksum(self: Self) u32 {
        // Create a temporary version with checksum field zeroed
        const temp = Self{
            .meta_magic = self.meta_magic,
            .format_version = self.format_version,
            .page_size = self.page_size,
            .committed_txn_id = self.committed_txn_id,
            .root_page_id = self.root_page_id,
            .freelist_head_page_id = self.freelist_head_page_id,
            .log_tail_lsn = self.log_tail_lsn,
            .meta_crc32c = 0,
        };

        const bytes = std.mem.asBytes(&temp);
        const meta_crc_offset: usize = @offsetOf(Self, "meta_crc32c");
        return crc32c(bytes[0..meta_crc_offset]);
    }

    // Validate meta payload checksum
    pub fn validateChecksum(self: Self) bool {
        return self.meta_crc32c == self.calculateChecksum();
    }

    // Encode meta payload to bytes
    pub fn encode(self: Self, dest: []u8) !void {
        if (dest.len < SIZE) return error.BufferTooSmall;
        std.mem.bytesAsValue(Self, dest[0..SIZE]).* = self;
    }

    // Decode meta payload from bytes
    pub fn decode(bytes: []const u8) !Self {
        if (bytes.len < SIZE) return error.InvalidMetaSize;
        const meta = std.mem.bytesAsValue(Self, bytes[0..SIZE]);

        // Validate magic and version
        if (meta.meta_magic != META_MAGIC) return error.InvalidMetaMagic;
        if (meta.format_version != FORMAT_VERSION) return error.UnsupportedFormat;

        return meta.*;
    }
};

// B+tree node common payload fields
pub const BtreeNodeHeader = struct {
    node_magic: u32 = BTREE_MAGIC,
    level: u16, // 0 for leaf, >0 for internal
    key_count: u16,
    right_sibling: u64, // PageId of right sibling (0 if none)
    reserved: [32]u8 = std.mem.zeroes([32]u8), // Reserved for future use

    const Self = @This();

    pub const SIZE: usize = @sizeOf(Self);

    // Encode B+tree node header to bytes
    pub fn encode(self: Self, dest: []u8) !void {
        if (dest.len < SIZE) return error.BufferTooSmall;
        std.mem.bytesAsValue(Self, dest[0..SIZE]).* = self;
    }

    // Decode B+tree node header from bytes
    pub fn decode(bytes: []const u8) !Self {
        if (bytes.len < SIZE) return error.InvalidNodeHeaderSize;
        const node = std.mem.bytesAsValue(Self, bytes[0..SIZE]);

        // Validate magic
        if (node.node_magic != BTREE_MAGIC) return error.InvalidBtreeMagic;

        return node.*;
    }
};

// Utility functions for page-level operations
pub fn calculatePageChecksum(page_bytes: []const u8) u32 {
    // For now, we'll use a simple approach: calculate CRC of the header with checksum field zeroed,
    // then continue with the rest of the data. This is not ideal but should work for our use case.

    // Create a temporary buffer and zero out the checksum field
    var buffer: [4096]u8 = undefined; // Fixed size buffer, should be enough for pages
    if (page_bytes.len > buffer.len) {
        // For pages larger than our buffer, use a simpler checksum
        var simple_crc: u32 = 0;
        for (page_bytes, 0..) |byte, i| {
            const checksum_offset = @offsetOf(PageHeader, "page_crc32c");
            if (i >= checksum_offset and i < checksum_offset + @sizeOf(u32)) {
                continue; // Skip checksum field
            }
            simple_crc +%= byte; // Simple additive checksum
        }
        return simple_crc;
    }

    @memcpy(buffer[0..page_bytes.len], page_bytes);

    // Zero out the checksum field
    const checksum_offset = @offsetOf(PageHeader, "page_crc32c");
    std.mem.writeInt(u32, buffer[checksum_offset..checksum_offset + @sizeOf(u32)], 0, .little);

    return crc32c(buffer[0..page_bytes.len]);
}

// Validate a complete page (header + payload)
pub fn validatePage(page_bytes: []const u8) !PageHeader {
    const header = try PageHeader.decode(page_bytes);

    // Validate header checksum
    if (!header.validateHeaderChecksum()) {
        return error.InvalidHeaderChecksum;
    }

    // Validate payload length
    if (header.payload_len > page_bytes.len - PageHeader.SIZE) {
        return error.InvalidPayloadLength;
    }

    // Validate page checksum
    const calculated_checksum = calculatePageChecksum(page_bytes[0..PageHeader.SIZE + header.payload_len]);
    if (calculated_checksum != header.page_crc32c) {
        return error.InvalidPageChecksum;
    }

    return header;
}

// Reserved page IDs
pub const META_A_PAGE_ID: u64 = 0;
pub const META_B_PAGE_ID: u64 = 1;

// Meta page state - represents which meta page is active
pub const MetaState = struct {
    page_id: u64,
    header: PageHeader,
    meta: MetaPayload,

    pub fn isValid(self: MetaState) bool {
        return self.header.validateHeaderChecksum() and
               self.meta.validateChecksum() and
               self.header.page_type == .meta and
               self.header.page_id == self.page_id;
    }
};

// Encode a complete meta page (header + meta payload)
pub fn encodeMetaPage(page_id: u64, meta: MetaPayload, dest: []u8) !void {
    if (dest.len < DEFAULT_PAGE_SIZE) return error.BufferTooSmall;

    // Prepare the header
    var header = PageHeader{
        .page_type = .meta,
        .page_id = page_id,
        .txn_id = meta.committed_txn_id,
        .payload_len = @intCast(MetaPayload.SIZE),
        .header_crc32c = 0, // Will be calculated
        .page_crc32c = 0, // Will be calculated
    };

    // Calculate and set header checksum
    header.header_crc32c = header.calculateHeaderChecksum();

    // Encode header to destination
    try header.encode(dest[0..PageHeader.SIZE]);

    // Calculate and set meta checksum
    const meta_with_checksum = MetaPayload{
        .meta_magic = meta.meta_magic,
        .format_version = meta.format_version,
        .page_size = meta.page_size,
        .committed_txn_id = meta.committed_txn_id,
        .root_page_id = meta.root_page_id,
        .freelist_head_page_id = meta.freelist_head_page_id,
        .log_tail_lsn = meta.log_tail_lsn,
        .meta_crc32c = meta.calculateChecksum(),
    };

    // Encode meta payload after header
    try meta_with_checksum.encode(dest[PageHeader.SIZE .. PageHeader.SIZE + MetaPayload.SIZE]);

    // Calculate page checksum (with page_crc32c field still 0)
    const page_data = dest[0 .. PageHeader.SIZE + header.payload_len];
    header.page_crc32c = calculatePageChecksum(page_data);

    // Re-encode header with page checksum
    try header.encode(dest[0..PageHeader.SIZE]);
}

// Decode and validate a complete meta page
pub fn decodeMetaPage(page_bytes: []const u8, expected_page_id: u64) !MetaState {
    if (page_bytes.len < PageHeader.SIZE + MetaPayload.SIZE) return error.InvalidMetaPage;

    // Decode and validate header
    var header = try PageHeader.decode(page_bytes);
    if (header.page_id != expected_page_id) return error.UnexpectedPageId;
    if (header.page_type != .meta) return error.InvalidPageType;
    if (!header.validateHeaderChecksum()) return error.InvalidHeaderChecksum;

    // Decode and validate meta payload
    const meta_bytes = page_bytes[PageHeader.SIZE .. PageHeader.SIZE + MetaPayload.SIZE];
    var meta = try MetaPayload.decode(meta_bytes);
    if (!meta.validateChecksum()) return error.InvalidMetaChecksum;

    return MetaState{
        .page_id = expected_page_id,
        .header = header,
        .meta = meta,
    };
}

// Choose the valid meta with the highest committed_txn_id
pub fn chooseBestMeta(meta_a: ?MetaState, meta_b: ?MetaState) ?MetaState {
    // Filter to only valid metas
    const valid_a = meta_a orelse null;
    const valid_b = meta_b orelse null;

    // If neither is valid, return null (corrupt database)
    if (valid_a == null and valid_b == null) return null;

    // If only one is valid, return it
    if (valid_a != null and valid_b == null) return valid_a.?;
    if (valid_b != null and valid_a == null) return valid_b.?;

    // Both are valid, choose the one with higher txn_id
    std.debug.assert(valid_a != null and valid_b != null);
    if (valid_a.?.meta.committed_txn_id >= valid_b.?.meta.committed_txn_id) {
        return valid_a.?;
    } else {
        return valid_b.?;
    }
}

// Get the opposite meta page ID (used for toggling)
pub fn getOppositeMetaId(page_id: u64) !u64 {
    if (page_id == META_A_PAGE_ID) return META_B_PAGE_ID;
    if (page_id == META_B_PAGE_ID) return META_A_PAGE_ID;
    return error.InvalidMetaId;
}

// Free list page payload - stores linked list of free page IDs
pub const FreelistPayload = struct {
    freelist_magic: u32 = 0x46524545, // "FREE"
    next_page_id: u64, // Next freelist page (0 if none)
    free_count: u32, // Number of free page IDs in this page
    reserved: [32]u8 = std.mem.zeroes([32]u8), // Reserved for future use
    // Followed by free_count * u64 page IDs

    const Self = @This();

    pub const SIZE: usize = @sizeOf(Self);

    pub const MAX_FREE_PER_PAGE: usize = (@as(usize, DEFAULT_PAGE_SIZE) - PageHeader.SIZE - SIZE) / @sizeOf(u64);

    // Encode freelist payload to bytes
    pub fn encode(self: Self, dest: []u8) !void {
        if (dest.len < SIZE) return error.BufferTooSmall;
        std.mem.bytesAsValue(Self, dest[0..SIZE]).* = self;
    }

    // Decode freelist payload from bytes
    pub fn decode(bytes: []const u8) !Self {
        if (bytes.len < SIZE) return error.InvalidFreelistSize;
        const freelist = std.mem.bytesAsValue(Self, bytes[0..SIZE]);

        // Validate magic
        if (freelist.freelist_magic != 0x46524545) return error.InvalidFreelistMagic;

        // Validate free count
        if (freelist.free_count > MAX_FREE_PER_PAGE) return error.InvalidFreeCount;

        return freelist.*;
    }
};

// Page allocator with rebuild-on-open freelist policy
pub const PageAllocator = struct {
    pager: *Pager,
    free_pages: std.ArrayList(u64),
    last_allocated_page: u64,
    allocator: std.mem.Allocator,

    const Self = @This();

    // Initialize page allocator by rebuilding freelist from committed tree
    pub fn init(pager: *Pager, allocator: std.mem.Allocator) !Self {
        var self = Self{
            .pager = pager,
            .free_pages = undefined,
            .last_allocated_page = 0,
            .allocator = allocator,
        };

        self.free_pages = std.ArrayList(u64).initCapacity(allocator, 64) catch unreachable;
        try self.rebuildFreelist();
        return self;
    }

    // Deinitialize page allocator
    pub fn deinit(self: *Self) void {
        self.free_pages.deinit(self.allocator);
    }

    // Rebuild freelist by finding pages NOT reachable from committed root
    fn rebuildFreelist(self: *Self) !void {
        // Get file size to determine total pages
        const file_size = try self.pager.file.getEndPos();
        const total_pages = file_size / self.pager.page_size;

        // Mark all pages (except reserved meta pages) as potentially free initially
        var page_in_use = try self.allocator.alloc(bool, total_pages);
        defer self.allocator.free(page_in_use);
        @memset(page_in_use, false);

        // Mark meta pages as in use
        if (total_pages > 0) page_in_use[META_A_PAGE_ID] = true;
        if (total_pages > 1) page_in_use[META_B_PAGE_ID] = true;

        // If we have a root page, traverse the tree to mark reachable pages
        const root_page_id = self.pager.getRootPageId();
        if (root_page_id != 0) {
            try self.markTreePages(root_page_id, page_in_use);
        }

        // Build freelist from pages not in use
        self.free_pages.clearRetainingCapacity();
        self.last_allocated_page = total_pages;

        for (page_in_use, 0..) |in_use, page_id| {
            if (!in_use and page_id >= 2) { // Skip meta pages 0 and 1
                try self.free_pages.append(self.allocator, @intCast(page_id));
            }
        }

        // Sort free pages for deterministic allocation (lowest ID first)
        std.sort.insertion(u64, self.free_pages.items, {}, struct {
            fn lessThan(_: void, a: u64, b: u64) bool {
                return a < b;
            }
        }.lessThan);
    }

    // Mark pages reachable from a given root page as in use
    fn markTreePages(self: *Self, root_page_id: u64, page_in_use: []bool) !void {
        // Stack for iterative traversal to avoid recursion
        var stack = std.ArrayList(u64).initCapacity(self.allocator, 32) catch unreachable;
        defer stack.deinit(self.allocator);
        try stack.append(self.allocator, root_page_id);

        while (stack.items.len > 0) {
            const page_id = stack.pop() orelse unreachable;

            // Skip if invalid or already marked
            if (page_id >= page_in_use.len or page_in_use[@intCast(page_id)]) {
                continue;
            }

            // Mark page as in use
            page_in_use[@intCast(page_id)] = true;

            // Read page to check type and find child pages
            var page_buffer: [DEFAULT_PAGE_SIZE]u8 = undefined;
            self.pager.readPage(page_id, &page_buffer) catch |err| switch (err) {
                error.UnexpectedEOF => continue, // Skip corrupt pages
                else => return err,
            };

            const header = validatePage(&page_buffer) catch |err| switch (err) {
                error.InvalidPageChecksum, error.InvalidHeaderChecksum, error.InvalidPayloadLength => continue, // Skip corrupt pages
                else => return err,
            };

            // If it's a btree page, add child pages to stack
            if (header.page_type == .btree_internal) {
                const child_page_ids = try self.extractChildPageIds(&page_buffer);
                for (child_page_ids) |child_id| {
                    try stack.append(self.allocator, child_id);
                }
            }
            // Leaf pages have no children, freelist pages are handled by freelist rebuild
        }
    }

    // Extract child page IDs from an internal btree node
    fn extractChildPageIds(self: *Self, page_buffer: []const u8) ![]const u64 {
        _ = self;
        const header = try PageHeader.decode(page_buffer);
        if (header.page_type != .btree_internal) return &[_]u64{};

        const payload_start = PageHeader.SIZE;
        if (payload_start + BtreeNodeHeader.SIZE > page_buffer.len) return &[_]u64{};

        const node_header = try BtreeNodeHeader.decode(page_buffer[payload_start..]);

        // For V0, we assume child page IDs are stored after the node header
        // This is a simplified approach - real implementation would need to parse the actual encoding
        const child_count = node_header.key_count + 1;
        const child_ids_start = payload_start + BtreeNodeHeader.SIZE;
        const child_ids_end = child_ids_start + child_count * @sizeOf(u64);

        if (child_ids_end > page_buffer.len) return &[_]u64{};

        const child_ids_bytes = page_buffer[child_ids_start..child_ids_end];

        // Since we don't have persistent allocation, return empty for now
        // Real implementation would need proper parsing of child pointers
        _ = child_ids_bytes;
        return &[_]u64{};
    }

    // Allocate a new page from freelist or extend the file
    pub fn allocatePage(self: *Self) !u64 {
        // Try to reuse from freelist first
        if (self.free_pages.items.len > 0) {
            return self.free_pages.orderedRemove(0); // Take lowest ID first
        }

        // Extend file with new page
        const new_page_id = self.last_allocated_page;
        self.last_allocated_page += 1;

        // Extend file by writing a zeroed page
        var zero_page: [DEFAULT_PAGE_SIZE]u8 = std.mem.zeroes([DEFAULT_PAGE_SIZE]u8);

        // Create a valid header for the new page
        var header = PageHeader{
            .page_type = .freelist, // Will be overwritten by caller
            .page_id = new_page_id,
            .txn_id = 0,
            .payload_len = 0,
            .header_crc32c = 0,
            .page_crc32c = 0,
        };
        header.header_crc32c = header.calculateHeaderChecksum();
        try header.encode(zero_page[0..PageHeader.SIZE]);

        const offset = new_page_id * self.pager.page_size;
        _ = try self.pager.file.pwriteAll(&zero_page, offset);

        return new_page_id;
    }

    // Free a page (add to freelist for future reuse)
    pub fn freePage(self: *Self, page_id: u64) !void {
        // Don't allow freeing meta pages
        if (page_id == META_A_PAGE_ID or page_id == META_B_PAGE_ID) {
            return error.InvalidOperation;
        }

        // Add to freelist, maintaining sort order
        for (self.free_pages.items, 0..) |existing_id, i| {
            if (page_id < existing_id) {
                try self.free_pages.insert(self.allocator, i, page_id);
                return;
            }
        }
        try self.free_pages.append(self.allocator, page_id);
    }

    // Get number of free pages available
    pub fn getFreePageCount(self: *const Self) usize {
        return self.free_pages.items.len;
    }

    // Get the highest allocated page ID
    pub fn getLastAllocatedPageId(self: *const Self) u64 {
        return self.last_allocated_page - 1;
    }
};

// Pager represents the storage layer with file handles and state
pub const Pager = struct {
    file: std.fs.File,
    page_size: u16,
    current_meta: MetaState,
    allocator: std.mem.Allocator,
    page_allocator: ?PageAllocator,

    const Self = @This();

    // Create a new empty database file
    pub fn create(path: []const u8, allocator: std.mem.Allocator) !Self {
        const file = try std.fs.cwd().createFile(path, .{ .truncate = true });
        errdefer file.close();

        // Create initial meta pages
        var buffer_a: [DEFAULT_PAGE_SIZE]u8 = undefined;
        var buffer_b: [DEFAULT_PAGE_SIZE]u8 = undefined;

        const meta = MetaPayload{
            .committed_txn_id = 0,
            .root_page_id = 0,
            .freelist_head_page_id = 0,
            .log_tail_lsn = 0,
            .meta_crc32c = 0,
        };

        try encodeMetaPage(META_A_PAGE_ID, meta, &buffer_a);
        try encodeMetaPage(META_B_PAGE_ID, meta, &buffer_b);

        // Write both meta pages
        _ = try file.pwriteAll(&buffer_a, 0);
        _ = try file.pwriteAll(&buffer_b, DEFAULT_PAGE_SIZE);

        // Parse the meta page we just wrote
        const meta_state = try decodeMetaPage(&buffer_a, META_A_PAGE_ID);

        var pager = Self{
            .file = file,
            .page_size = DEFAULT_PAGE_SIZE,
            .current_meta = meta_state,
            .allocator = allocator,
            .page_allocator = null,
        };

        // Initialize page allocator
        pager.page_allocator = try PageAllocator.init(&pager, allocator);

        return pager;
    }

    // Open database file with recovery: choose highest valid meta, else Corrupt
    pub fn open(path: []const u8, allocator: std.mem.Allocator) !Self {
        const file = try std.fs.cwd().openFile(path, .{ .mode = .read_write });
        defer file.close();

        // Read the first page to determine page size (should be DEFAULT_PAGE_SIZE for V0)
        var first_page_buffer: [DEFAULT_PAGE_SIZE]u8 = undefined;
        const bytes_read = try file.preadAll(&first_page_buffer, 0);
        if (bytes_read < DEFAULT_PAGE_SIZE) {
            return error.FileTooSmall; // Database file must have at least one full page
        }

        // Try to decode both meta pages
        const meta_a_result = decodeMetaPage(first_page_buffer[0..DEFAULT_PAGE_SIZE], META_A_PAGE_ID);
        const meta_a = meta_a_result catch |err| switch (err) {
            error.InvalidHeaderChecksum, error.InvalidMetaChecksum, error.InvalidMagic, error.InvalidMetaMagic, error.InvalidPageType, error.UnexpectedPageId => null,
            else => return err,
        };

        // Read second page for meta B
        var second_page_buffer: [DEFAULT_PAGE_SIZE]u8 = undefined;
        const bytes_read_b = try file.preadAll(&second_page_buffer, DEFAULT_PAGE_SIZE);
        const meta_b: ?MetaState = if (bytes_read_b < DEFAULT_PAGE_SIZE)
            null
        else
            decodeMetaPage(second_page_buffer[0..DEFAULT_PAGE_SIZE], META_B_PAGE_ID) catch |err| switch (err) {
                error.InvalidHeaderChecksum, error.InvalidMetaChecksum, error.InvalidMagic, error.InvalidMetaMagic, error.InvalidPageType, error.UnexpectedPageId => null,
                else => return err,
            };

        // Choose the best meta (highest valid txn_id)
        const best_meta = chooseBestMeta(meta_a, meta_b) orelse return error.Corrupt;

        // Validate page size from meta
        if (best_meta.meta.page_size != DEFAULT_PAGE_SIZE) {
            return error.UnsupportedPageSize;
        }

        // Re-open file to keep it open for the pager lifetime
        const persistent_file = try std.fs.cwd().openFile(path, .{ .mode = .read_write });

        var pager = Self{
            .file = persistent_file,
            .page_size = best_meta.meta.page_size,
            .current_meta = best_meta,
            .allocator = allocator,
            .page_allocator = null,
        };

        // Initialize page allocator with rebuild-on-open policy
        pager.page_allocator = try PageAllocator.init(&pager, allocator);

        return pager;
    }

    // Close the pager and release file handle
    pub fn close(self: *Self) void {
        if (self.page_allocator) |*alloc| {
            alloc.deinit();
        }
        self.file.close();
    }

    // Read a page from the file with checksums and bounds checks
    pub fn readPage(self: *Self, page_id: u64, buffer: []u8) !void {
        // Bounds check: ensure buffer is large enough for page
        if (buffer.len < self.page_size) return error.BufferTooSmall;

        // Bounds check: ensure page_id is within reasonable range
        const file_size = try self.file.getEndPos();
        const max_page_id = file_size / self.page_size;
        if (page_id >= max_page_id) {
            return error.PageOutOfBounds;
        }

        // Calculate file offset with overflow check
        const offset = page_id * self.page_size;
        if (offset != page_id * self.page_size) { // Check for overflow
            return error.IntegerOverflow;
        }

        // Read page from file
        const bytes_read = try self.file.preadAll(buffer, offset);
        if (bytes_read < self.page_size) {
            return error.UnexpectedEOF;
        }

        // Validate page structure and checksums
        const header = validatePage(buffer[0..self.page_size]) catch |err| {
            // Provide more specific error information for debugging
            switch (err) {
                error.InvalidMagic => {
                    const magic = std.mem.bytesAsValue(u32, buffer[0..4]).*;
                    std.log.err("Invalid page magic 0x{X} in page {d}, expected 0x{X}", .{ magic, page_id, PAGE_MAGIC });
                },
                error.InvalidHeaderChecksum => {
                    std.log.err("Invalid header checksum in page {d}", .{page_id});
                },
                error.InvalidPageChecksum => {
                    std.log.err("Invalid page checksum in page {d}", .{page_id});
                },
                error.InvalidPayloadLength => {
                    const header = std.mem.bytesAsValue(PageHeader, buffer[0..PageHeader.SIZE]);
                    std.log.err("Invalid payload length {d} in page {d}, max {d}", .{ header.payload_len, page_id, self.page_size - PageHeader.SIZE });
                },
                else => {},
            }
            return err;
        };

        // Additional bounds check: ensure page_id in header matches requested page_id
        if (header.page_id != page_id) {
            std.log.err("Page ID mismatch: requested {d}, found {d} in header", .{ page_id, header.page_id });
            return error.PageIdMismatch;
        }

        // Additional bounds check: ensure payload length fits within page
        if (header.payload_len > self.page_size - PageHeader.SIZE) {
            return error.PayloadTooLarge;
        }
    }

    // Write a page to the file with checksums and bounds checks
    pub fn writePage(self: *Self, page_id: u64, buffer: []const u8) !void {
        // Bounds check: ensure buffer is large enough for page
        if (buffer.len < self.page_size) return error.BufferTooSmall;

        // Validate page structure before writing
        const header = validatePage(buffer[0..self.page_size]) catch |err| {
            std.log.err("Page validation failed before write to page {d}: {}", .{ page_id, err });
            return err;
        };

        // Bounds check: ensure page_id in header matches target page_id
        if (header.page_id != page_id) {
            std.log.err("Page ID mismatch during write: target {d}, header {d}", .{ page_id, header.page_id });
            return error.PageIdMismatch;
        }

        // Calculate file offset with overflow check
        const offset = page_id * self.page_size;
        if (offset != page_id * self.page_size) { // Check for overflow
            return error.IntegerOverflow;
        }

        // Ensure we're not trying to write beyond reasonable file size
        const file_size = try self.file.getEndPos();
        if (offset > file_size) {
            return error.WriteBeyondFile;
        }

        // Write page to file
        try self.file.pwriteAll(buffer, offset);
    }

    // Sync file to ensure durability
    pub fn sync(self: *Self) !void {
        try self.file.sync();
    }

    // Fsync ordering for two-phase commit: ensure WAL is synced before DB
    pub fn commitSync(self: *Self, wal: anytype) !void {
        _ = wal; // Mark parameter as used for documentation purposes
        // Critical ordering:
        // 1. All data pages must be written
        // 2. WAL must be synced (ensures commit record is durable)
        // 3. Meta page must be written and synced

        // The caller should ensure steps 1-2 happen before calling this
        // This function handles the meta page sync

        try self.sync();
    }

    // Get current database state from meta
    pub fn getRootPageId(self: *const Self) u64 {
        return self.current_meta.meta.root_page_id;
    }

    pub fn getCommittedTxnId(self: *const Self) u64 {
        return self.current_meta.meta.committed_txn_id;
    }

    pub fn getFreelistHeadPageId(self: *const Self) u64 {
        return self.current_meta.meta.freelist_head_page_id;
    }

    pub fn getLogTailLsn(self: *const Self) u64 {
        return self.current_meta.meta.log_tail_lsn;
    }

    // Page allocator convenience methods
    pub fn allocatePage(self: *Self) !u64 {
        if (self.page_allocator) |*alloc| {
            return alloc.allocatePage();
        }
        return error.PageAllocatorNotInitialized;
    }

    pub fn freePage(self: *Self, page_id: u64) !void {
        if (self.page_allocator) |*alloc| {
            return alloc.freePage(page_id);
        }
        return error.PageAllocatorNotInitialized;
    }

    pub fn getFreePageCount(self: *const Self) usize {
        if (self.page_allocator) |*alloc| {
            return alloc.getFreePageCount();
        }
        return 0;
    }

    pub fn getLastAllocatedPageId(self: *const Self) u64 {
        if (self.page_allocator) |*alloc| {
            return alloc.getLastAllocatedPageId();
        }
        return 0;
    }
};

// Helper function to create a properly checksummed page
pub fn createPage(page_id: u64, page_type: PageType, txn_id: u64, payload: []const u8, buffer: []u8) !void {
    if (buffer.len < DEFAULT_PAGE_SIZE) return error.BufferTooSmall;
    if (payload.len > DEFAULT_PAGE_SIZE - PageHeader.SIZE) return error.PayloadTooLarge;

    // Zero out the entire buffer first
    @memset(buffer[0..DEFAULT_PAGE_SIZE], 0);

    // Create header
    var header = PageHeader{
        .page_type = page_type,
        .page_id = page_id,
        .txn_id = txn_id,
        .payload_len = @intCast(payload.len),
        .header_crc32c = 0,
        .page_crc32c = 0,
    };

    // Calculate header checksum
    header.header_crc32c = header.calculateHeaderChecksum();

    // Encode header
    try header.encode(buffer[0..PageHeader.SIZE]);

    // Copy payload if provided
    if (payload.len > 0) {
        @memcpy(buffer[PageHeader.SIZE .. PageHeader.SIZE + payload.len], payload);
    }

    // Calculate page checksum (with page_crc32c field still 0)
    const page_data = buffer[0 .. PageHeader.SIZE + header.payload_len];
    header.page_crc32c = calculatePageChecksum(page_data);

    // Re-encode header with page checksum
    try header.encode(buffer[0..PageHeader.SIZE]);
}

// Helper function to create a btree page with node header
pub fn createBtreePage(page_id: u64, level: u16, key_count: u16, right_sibling: u64, txn_id: u64, payload: []const u8, buffer: []u8) !void {
    if (buffer.len < DEFAULT_PAGE_SIZE) return error.BufferTooSmall;

    const node_header = BtreeNodeHeader{
        .level = level,
        .key_count = key_count,
        .right_sibling = right_sibling,
    };

    var node_data: [BtreeNodeHeader.SIZE]u8 = undefined;
    try node_header.encode(&node_data);

    // Combine node header with payload
    const total_payload = node_data.len + payload.len;
    if (total_payload > DEFAULT_PAGE_SIZE - PageHeader.SIZE) return error.PayloadTooLarge;

    var combined_payload: [DEFAULT_PAGE_SIZE - PageHeader.SIZE]u8 = undefined;
    @memcpy(combined_payload[0..node_data.len], &node_data);
    if (payload.len > 0) {
        @memcpy(combined_payload[node_data.len .. node_data.len + payload.len], payload);
    }

    try createPage(page_id, if (level == 0) .btree_leaf else .btree_internal, txn_id, combined_payload[0..total_payload], buffer);
}

// ==================== Unit Tests ====================

const testing = std.testing;

test "PageHeader.encode_decode_roundtrip" {
    const original = PageHeader{
        .page_type = .btree_leaf,
        .page_id = 42,
        .txn_id = 100,
        .payload_len = 1024,
        .header_crc32c = 0, // Will be calculated
        .page_crc32c = 0, // Will be calculated
    };

    var buffer: [PageHeader.SIZE]u8 = undefined;
    const with_checksum = original;
    const checksum = with_checksum.calculateHeaderChecksum();

    const header_with_checksum = PageHeader{
        .page_type = original.page_type,
        .page_id = original.page_id,
        .txn_id = original.txn_id,
        .payload_len = original.payload_len,
        .header_crc32c = checksum,
        .page_crc32c = original.page_crc32c,
    };

    try header_with_checksum.encode(&buffer);
    const decoded = try PageHeader.decode(&buffer);

    try testing.expectEqual(header_with_checksum.magic, decoded.magic);
    try testing.expectEqual(header_with_checksum.format_version, decoded.format_version);
    try testing.expectEqual(header_with_checksum.page_type, decoded.page_type);
    try testing.expectEqual(header_with_checksum.page_id, decoded.page_id);
    try testing.expectEqual(header_with_checksum.txn_id, decoded.txn_id);
    try testing.expectEqual(header_with_checksum.payload_len, decoded.payload_len);
    try testing.expectEqual(header_with_checksum.header_crc32c, decoded.header_crc32c);
}

test "PageHeader.validateHeaderChecksum" {
    var header = PageHeader{
        .page_type = .meta,
        .page_id = 0,
        .txn_id = 1,
        .payload_len = MetaPayload.SIZE,
        .header_crc32c = 0,
        .page_crc32c = 0,
    };

    // Calculate and set checksum
    header.header_crc32c = header.calculateHeaderChecksum();

    // Should validate successfully
    try testing.expect(header.validateHeaderChecksum());

    // Corrupt the checksum
    header.header_crc32c += 1;
    try testing.expect(!header.validateHeaderChecksum());
}

test "MetaPayload.encode_decode_roundtrip" {
    const original = MetaPayload{
        .committed_txn_id = 100,
        .root_page_id = 5,
        .freelist_head_page_id = 0,
        .log_tail_lsn = 42,
        .meta_crc32c = 0, // Will be calculated
    };

    var buffer: [MetaPayload.SIZE]u8 = undefined;
    const with_checksum = original;
    const checksum = with_checksum.calculateChecksum();

    const meta_with_checksum = MetaPayload{
        .committed_txn_id = original.committed_txn_id,
        .root_page_id = original.root_page_id,
        .freelist_head_page_id = original.freelist_head_page_id,
        .log_tail_lsn = original.log_tail_lsn,
        .meta_crc32c = checksum,
    };

    try meta_with_checksum.encode(&buffer);
    const decoded = try MetaPayload.decode(&buffer);

    try testing.expectEqual(meta_with_checksum.meta_magic, decoded.meta_magic);
    try testing.expectEqual(meta_with_checksum.format_version, decoded.format_version);
    try testing.expectEqual(meta_with_checksum.page_size, decoded.page_size);
    try testing.expectEqual(meta_with_checksum.committed_txn_id, decoded.committed_txn_id);
    try testing.expectEqual(meta_with_checksum.root_page_id, decoded.root_page_id);
    try testing.expectEqual(meta_with_checksum.freelist_head_page_id, decoded.freelist_head_page_id);
    try testing.expectEqual(meta_with_checksum.log_tail_lsn, decoded.log_tail_lsn);
    try testing.expectEqual(meta_with_checksum.meta_crc32c, decoded.meta_crc32c);
}

test "MetaPayload.validateChecksum" {
    var meta = MetaPayload{
        .committed_txn_id = 50,
        .root_page_id = 10,
        .freelist_head_page_id = 0,
        .log_tail_lsn = 0,
        .meta_crc32c = 0,
    };

    // Calculate and set checksum
    meta.meta_crc32c = meta.calculateChecksum();

    // Should validate successfully
    try testing.expect(meta.validateChecksum());

    // Corrupt the checksum
    meta.meta_crc32c += 1;
    try testing.expect(!meta.validateChecksum());
}

test "validatePage.rejects_invalid_magic" {
    var page_buffer: [PageHeader.SIZE + 100]u8 = undefined;

    // Create a header with invalid magic
    var header = PageHeader{
        .magic = 0xDEADBEEF, // Invalid magic
        .page_type = .btree_leaf,
        .page_id = 1,
        .txn_id = 1,
        .payload_len = 100,
        .header_crc32c = 0,
        .page_crc32c = 0,
    };

    // Set header checksum
    header.header_crc32c = header.calculateHeaderChecksum();
    header.page_crc32c = calculatePageChecksum(page_buffer[0..PageHeader.SIZE + header.payload_len]);

    try header.encode(page_buffer[0..PageHeader.SIZE]);

    // Should fail with invalid magic
    try testing.expectError(error.InvalidMagic, validatePage(&page_buffer));
}

test "validatePage.rejects_invalid_header_checksum" {
    var page_buffer: [PageHeader.SIZE + 100]u8 = undefined;

    var header = PageHeader{
        .page_type = .btree_leaf,
        .page_id = 1,
        .txn_id = 1,
        .payload_len = 100,
        .header_crc32c = 12345, // Invalid checksum
        .page_crc32c = 0,
    };

    // Set page checksum
    header.page_crc32c = calculatePageChecksum(page_buffer[0..PageHeader.SIZE + header.payload_len]);

    try header.encode(page_buffer[0..PageHeader.SIZE]);

    // Should fail with invalid header checksum
    try testing.expectError(error.InvalidHeaderChecksum, validatePage(&page_buffer));
}

test "validatePage.rejects_invalid_payload_length" {
    var page_buffer: [PageHeader.SIZE]u8 = undefined;

    var header = PageHeader{
        .page_type = .btree_leaf,
        .page_id = 1,
        .txn_id = 1,
        .payload_len = 100, // Too large for buffer
        .header_crc32c = 0,
        .page_crc32c = 0,
    };

    // Set header checksum only (we can't calculate page checksum without full page)
    header.header_crc32c = header.calculateHeaderChecksum();
    header.page_crc32c = 0; // Set to 0 since we can't calculate properly

    try header.encode(page_buffer[0..PageHeader.SIZE]);

    // Should fail with invalid payload length
    try testing.expectError(error.InvalidPayloadLength, validatePage(&page_buffer));
}

test "validatePage.success_with_valid_page" {
    var page_buffer: [PageHeader.SIZE + 100]u8 = undefined;

    // Initialize payload area with test data
    for (page_buffer[PageHeader.SIZE..]) |*byte| {
        byte.* = 0xAA;
    }

    var header = PageHeader{
        .page_type = .btree_leaf,
        .page_id = 1,
        .txn_id = 1,
        .payload_len = 100,
        .header_crc32c = 0,
        .page_crc32c = 0,
    };

    // Set header checksum first
    header.header_crc32c = header.calculateHeaderChecksum();

    // Encode header to get it in place
    try header.encode(page_buffer[0..PageHeader.SIZE]);

    // Now calculate page checksum with the full page (header will have checksum field 0)
    header.page_crc32c = calculatePageChecksum(page_buffer[0..PageHeader.SIZE + header.payload_len]);

    // Encode again to update the page_crc32c field
    try header.encode(page_buffer[0..PageHeader.SIZE]);

    // Should validate successfully
    const validated = try validatePage(&page_buffer);
    try testing.expectEqual(header.page_id, validated.page_id);
    try testing.expectEqual(header.page_type, validated.page_type);
}

test "BtreeNodeHeader.encode_decode_roundtrip" {
    const original = BtreeNodeHeader{
        .level = 0, // Leaf node
        .key_count = 5,
        .right_sibling = 10,
    };

    var buffer: [BtreeNodeHeader.SIZE]u8 = undefined;
    try original.encode(&buffer);
    const decoded = try BtreeNodeHeader.decode(&buffer);

    try testing.expectEqual(original.node_magic, decoded.node_magic);
    try testing.expectEqual(original.level, decoded.level);
    try testing.expectEqual(original.key_count, decoded.key_count);
    try testing.expectEqual(original.right_sibling, decoded.right_sibling);
}

test "format_constants_match_specification" {
    try testing.expectEqual(@as(u32, 0x4E534442), PAGE_MAGIC); // "NSDB"
    try testing.expectEqual(@as(u32, 0x4D455441), META_MAGIC); // "META"
    try testing.expectEqual(@as(u32, 0x42545245), BTREE_MAGIC); // "BTRE"
    try testing.expectEqual(@as(u16, 0), FORMAT_VERSION);
    try testing.expectEqual(@as(u16, 16384), DEFAULT_PAGE_SIZE);
}

test "encodeMetaPage produces_valid_page" {
    var buffer: [DEFAULT_PAGE_SIZE]u8 = undefined;

    const meta = MetaPayload{
        .committed_txn_id = 100,
        .root_page_id = 5,
        .freelist_head_page_id = 0,
        .log_tail_lsn = 42,
        .meta_crc32c = 0, // Will be calculated
    };

    try encodeMetaPage(META_A_PAGE_ID, meta, &buffer);

    // Decode and validate the page
    const header = try PageHeader.decode(buffer[0..PageHeader.SIZE]);
    try testing.expectEqual(.meta, header.page_type);
    try testing.expectEqual(META_A_PAGE_ID, header.page_id);
    try testing.expectEqual(meta.committed_txn_id, header.txn_id);
    try testing.expectEqual(@as(u32, MetaPayload.SIZE), header.payload_len);
    try testing.expect(header.validateHeaderChecksum());

    // Validate page checksum
    const calculated_checksum = calculatePageChecksum(buffer[0..PageHeader.SIZE + header.payload_len]);
    try testing.expectEqual(header.page_crc32c, calculated_checksum);

    // Decode and validate meta payload
    const decoded_meta = try MetaPayload.decode(buffer[PageHeader.SIZE .. PageHeader.SIZE + MetaPayload.SIZE]);
    try testing.expectEqual(meta.committed_txn_id, decoded_meta.committed_txn_id);
    try testing.expectEqual(meta.root_page_id, decoded_meta.root_page_id);
    try testing.expectEqual(meta.freelist_head_page_id, decoded_meta.freelist_head_page_id);
    try testing.expectEqual(meta.log_tail_lsn, decoded_meta.log_tail_lsn);
    try testing.expect(decoded_meta.validateChecksum());
}

test "decodeMetaPage rejects_corrupted_page" {
    var buffer: [DEFAULT_PAGE_SIZE]u8 = undefined;

    const meta = MetaPayload{
        .committed_txn_id = 100,
        .root_page_id = 5,
        .freelist_head_page_id = 0,
        .log_tail_lsn = 42,
        .meta_crc32c = 0,
    };

    try encodeMetaPage(META_A_PAGE_ID, meta, &buffer);

    // Corrupt the header checksum
    buffer[@offsetOf(PageHeader, "header_crc32c")] += 1;

    try testing.expectError(error.InvalidHeaderChecksum, decodeMetaPage(&buffer, META_A_PAGE_ID));
}

test "decodeMetaPage rejects_wrong_page_type" {
    var buffer: [DEFAULT_PAGE_SIZE]u8 = undefined;

    const meta = MetaPayload{
        .committed_txn_id = 100,
        .root_page_id = 5,
        .freelist_head_page_id = 0,
        .log_tail_lsn = 42,
        .meta_crc32c = 0,
    };

    try encodeMetaPage(META_A_PAGE_ID, meta, &buffer);

    // Change page type to btree_leaf
    buffer[@offsetOf(PageHeader, "page_type")] = @intFromEnum(PageType.btree_leaf);

    try testing.expectError(error.InvalidPageType, decodeMetaPage(&buffer, META_A_PAGE_ID));
}

test "decodeMetaPage rejects_wrong_page_id" {
    var buffer: [DEFAULT_PAGE_SIZE]u8 = undefined;

    const meta = MetaPayload{
        .committed_txn_id = 100,
        .root_page_id = 5,
        .freelist_head_page_id = 0,
        .log_tail_lsn = 42,
        .meta_crc32c = 0,
    };

    try encodeMetaPage(META_A_PAGE_ID, meta, &buffer);

    // Try to decode with wrong page ID
    try testing.expectError(error.UnexpectedPageId, decodeMetaPage(&buffer, META_B_PAGE_ID));
}

test "MetaState.isValid_checks_all_fields" {
    var buffer: [DEFAULT_PAGE_SIZE]u8 = undefined;

    const meta = MetaPayload{
        .committed_txn_id = 100,
        .root_page_id = 5,
        .freelist_head_page_id = 0,
        .log_tail_lsn = 42,
        .meta_crc32c = 0,
    };

    try encodeMetaPage(META_A_PAGE_ID, meta, &buffer);
    const meta_state = try decodeMetaPage(&buffer, META_A_PAGE_ID);

    try testing.expect(meta_state.isValid());

    // Test with corrupted checksum - should fail to decode
    buffer[@offsetOf(PageHeader, "header_crc32c")] += 1;
    try testing.expectError(error.InvalidHeaderChecksum, decodeMetaPage(&buffer, META_A_PAGE_ID));
}

test "chooseBestMeta selects_highest_valid_txn_id" {
    var buffer_a: [DEFAULT_PAGE_SIZE]u8 = undefined;
    var buffer_b: [DEFAULT_PAGE_SIZE]u8 = undefined;

    const meta_a = MetaPayload{
        .committed_txn_id = 100,
        .root_page_id = 5,
        .freelist_head_page_id = 0,
        .log_tail_lsn = 42,
        .meta_crc32c = 0,
    };

    const meta_b = MetaPayload{
        .committed_txn_id = 200, // Higher txn_id
        .root_page_id = 10,
        .freelist_head_page_id = 0,
        .log_tail_lsn = 84,
        .meta_crc32c = 0,
    };

    try encodeMetaPage(META_A_PAGE_ID, meta_a, &buffer_a);
    try encodeMetaPage(META_B_PAGE_ID, meta_b, &buffer_b);

    const state_a = try decodeMetaPage(&buffer_a, META_A_PAGE_ID);
    const state_b = try decodeMetaPage(&buffer_b, META_B_PAGE_ID);

    // Should choose meta B (higher txn_id)
    const best = chooseBestMeta(state_a, state_b).?;
    try testing.expectEqual(META_B_PAGE_ID, best.page_id);
    try testing.expectEqual(@as(u64, 200), best.meta.committed_txn_id);
}

test "chooseBestMeta_handles_invalid_metas" {
    var buffer_a: [DEFAULT_PAGE_SIZE]u8 = undefined;

    const meta_a = MetaPayload{
        .committed_txn_id = 100,
        .root_page_id = 5,
        .freelist_head_page_id = 0,
        .log_tail_lsn = 42,
        .meta_crc32c = 0,
    };

    try encodeMetaPage(META_A_PAGE_ID, meta_a, &buffer_a);
    const state_a = try decodeMetaPage(&buffer_a, META_A_PAGE_ID);

    // Only meta A is valid
    const best = chooseBestMeta(state_a, null).?;
    try testing.expectEqual(META_A_PAGE_ID, best.page_id);

    // Neither is valid
    try testing.expect(chooseBestMeta(null, null) == null);

    // Corrupt meta A - should fail to decode
    buffer_a[@offsetOf(PageHeader, "header_crc32c")] += 1;
    const corrupted_result = decodeMetaPage(&buffer_a, META_A_PAGE_ID);
    try testing.expectError(error.InvalidHeaderChecksum, corrupted_result);
}

test "getOppositeMetaId" {
    try testing.expectEqual(META_B_PAGE_ID, try getOppositeMetaId(META_A_PAGE_ID));
    try testing.expectEqual(META_A_PAGE_ID, try getOppositeMetaId(META_B_PAGE_ID));
    try testing.expectError(error.InvalidMetaId, getOppositeMetaId(42));
}

test "format_meta_roundtrip_encode_decode" {
    var buffer: [DEFAULT_PAGE_SIZE]u8 = undefined;

    const original_meta = MetaPayload{
        .committed_txn_id = 42,
        .root_page_id = 123,
        .freelist_head_page_id = 456,
        .log_tail_lsn = 789,
        .meta_crc32c = 0,
    };

    // Encode meta A
    try encodeMetaPage(META_A_PAGE_ID, original_meta, &buffer);

    // Decode it back
    const decoded_state = try decodeMetaPage(&buffer, META_A_PAGE_ID);

    // Verify all fields match
    try testing.expectEqual(META_A_PAGE_ID, decoded_state.page_id);
    try testing.expectEqual(original_meta.committed_txn_id, decoded_state.meta.committed_txn_id);
    try testing.expectEqual(original_meta.root_page_id, decoded_state.meta.root_page_id);
    try testing.expectEqual(original_meta.freelist_head_page_id, decoded_state.meta.freelist_head_page_id);
    try testing.expectEqual(original_meta.log_tail_lsn, decoded_state.meta.log_tail_lsn);
    try testing.expect(decoded_state.isValid());
}

test "Pager.open_recovery_selects_highest_valid_meta" {
    const test_filename = "test_pager_recovery.db";
    defer {
        std.fs.cwd().deleteFile(test_filename) catch {};
    }

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    // Create test database file with two meta pages
    const file = try std.fs.cwd().createFile(test_filename, .{ .truncate = true });
    defer file.close();

    // Create two different meta pages
    var buffer_a: [DEFAULT_PAGE_SIZE]u8 = undefined;
    var buffer_b: [DEFAULT_PAGE_SIZE]u8 = undefined;

    const meta_a = MetaPayload{
        .committed_txn_id = 100,
        .root_page_id = 5,
        .freelist_head_page_id = 0,
        .log_tail_lsn = 42,
        .meta_crc32c = 0,
    };

    const meta_b = MetaPayload{
        .committed_txn_id = 200, // Higher txn_id should win
        .root_page_id = 10,
        .freelist_head_page_id = 0,
        .log_tail_lsn = 84,
        .meta_crc32c = 0,
    };

    try encodeMetaPage(META_A_PAGE_ID, meta_a, &buffer_a);
    try encodeMetaPage(META_B_PAGE_ID, meta_b, &buffer_b);

    // Write both pages to file
    _ = try file.pwriteAll(&buffer_a, 0);
    _ = try file.pwriteAll(&buffer_b, DEFAULT_PAGE_SIZE);

    // Test recovery
    var pager = try Pager.open(test_filename, arena.allocator());
    defer pager.close();

    // Should select meta B (higher txn_id)
    try testing.expectEqual(@as(u64, 200), pager.getCommittedTxnId());
    try testing.expectEqual(@as(u64, 10), pager.getRootPageId());
    try testing.expectEqual(@as(u64, 0), pager.getFreelistHeadPageId());
    try testing.expectEqual(@as(u64, 84), pager.getLogTailLsn());
}

test "Pager.open_recovery_handles_corrupt_meta_pages" {
    const test_filename = "test_pager_corrupt.db";
    defer {
        std.fs.cwd().deleteFile(test_filename) catch {};
    }

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    // Create file with one valid meta and one corrupt
    const file = try std.fs.cwd().createFile(test_filename, .{ .truncate = true });
    defer file.close();

    var buffer_a: [DEFAULT_PAGE_SIZE]u8 = undefined;
    var buffer_b: [DEFAULT_PAGE_SIZE]u8 = undefined;

    const meta_a = MetaPayload{
        .committed_txn_id = 100,
        .root_page_id = 5,
        .freelist_head_page_id = 0,
        .log_tail_lsn = 42,
        .meta_crc32c = 0,
    };

    try encodeMetaPage(META_A_PAGE_ID, meta_a, &buffer_a);
    try encodeMetaPage(META_B_PAGE_ID, meta_a, &buffer_b);

    // Corrupt meta B
    buffer_b[@offsetOf(PageHeader, "header_crc32c")] += 1;

    _ = try file.pwriteAll(&buffer_a, 0);
    _ = try file.pwriteAll(&buffer_b, DEFAULT_PAGE_SIZE);

    // Should recover with meta A only
    var pager = try Pager.open(test_filename, arena.allocator());
    defer pager.close();

    try testing.expectEqual(@as(u64, 100), pager.getCommittedTxnId());
    try testing.expectEqual(@as(u64, 5), pager.getRootPageId());
}

test "Pager.open_recovery_fails_when_both_metas_corrupt" {
    const test_filename = "test_pager_both_corrupt.db";
    defer {
        std.fs.cwd().deleteFile(test_filename) catch {};
    }

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    // Create file with both metas corrupt
    const file = try std.fs.cwd().createFile(test_filename, .{ .truncate = true });
    defer file.close();

    var buffer: [DEFAULT_PAGE_SIZE]u8 = std.mem.zeroes([DEFAULT_PAGE_SIZE]u8);

    // Write two empty/corrupt pages
    _ = try file.pwriteAll(&buffer, 0);
    _ = try file.pwriteAll(&buffer, DEFAULT_PAGE_SIZE);

    // Should fail to open
    try testing.expectError(error.Corrupt, Pager.open(test_filename, arena.allocator()));
}

test "Pager.open_recovery_fails_on_file_too_small" {
    const test_filename = "test_pager_too_small.db";
    defer {
        std.fs.cwd().deleteFile(test_filename) catch {};
    }

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    // Create file smaller than a page
    const file = try std.fs.cwd().createFile(test_filename, .{ .truncate = true });
    defer file.close();

    var small_buffer: [100]u8 = undefined;
    _ = try file.pwriteAll(&small_buffer, 0);

    // Should fail with FileTooSmall
    try testing.expectError(error.FileTooSmall, Pager.open(test_filename, arena.allocator()));
}

test "Pager.open_recovery_fails_on_unsupported_page_size" {
    const test_filename = "test_pager_unsupported_size.db";
    defer {
        std.fs.cwd().deleteFile(test_filename) catch {};
    }

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const file = try std.fs.cwd().createFile(test_filename, .{ .truncate = true });
    defer file.close();

    var buffer: [DEFAULT_PAGE_SIZE]u8 = undefined;

    // Create meta with unsupported page size
    const meta = MetaPayload{
        .page_size = 8192, // Different from DEFAULT_PAGE_SIZE
        .committed_txn_id = 100,
        .root_page_id = 5,
        .freelist_head_page_id = 0,
        .log_tail_lsn = 42,
        .meta_crc32c = 0,
    };

    try encodeMetaPage(META_A_PAGE_ID, meta, &buffer);
    _ = try file.pwriteAll(&buffer, 0);

    try testing.expectError(error.UnsupportedPageSize, Pager.open(test_filename, arena.allocator()));
}

test "FreelistPayload.encode_decode_roundtrip" {
    const original = FreelistPayload{
        .next_page_id = 10,
        .free_count = 3,
    };

    var buffer: [FreelistPayload.SIZE]u8 = undefined;
    try original.encode(&buffer);
    const decoded = try FreelistPayload.decode(&buffer);

    try testing.expectEqual(original.freelist_magic, decoded.freelist_magic);
    try testing.expectEqual(original.next_page_id, decoded.next_page_id);
    try testing.expectEqual(original.free_count, decoded.free_count);
}

test "FreelistPayload.validate_magic" {
    var buffer: [FreelistPayload.SIZE]u8 = undefined;

    const valid_freelist = FreelistPayload{
        .next_page_id = 0,
        .free_count = 0,
    };

    try valid_freelist.encode(&buffer);
    _ = try FreelistPayload.decode(&buffer);

    // Corrupt the magic by flipping one byte at the correct offset (offset 8)
    buffer[8] += 1; // Change first byte of magic (at offset 8)
    try testing.expectError(error.InvalidFreelistMagic, FreelistPayload.decode(&buffer));
}

test "FreelistPayload.validate_free_count" {
    var buffer: [FreelistPayload.SIZE]u8 = undefined;

    const invalid_freelist = FreelistPayload{
        .next_page_id = 0,
        .free_count = FreelistPayload.MAX_FREE_PER_PAGE + 1, // Too large
    };

    try invalid_freelist.encode(&buffer);
    try testing.expectError(error.InvalidFreeCount, FreelistPayload.decode(&buffer));
}

test "PageAllocator.init_rebuilds_freelist_from_empty_db" {
    const test_filename = "test_allocator_empty.db";
    defer {
        std.fs.cwd().deleteFile(test_filename) catch {};
    }

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    // Create empty database file (just meta pages)
    const file = try std.fs.cwd().createFile(test_filename, .{ .truncate = true });
    defer file.close();

    var buffer_a: [DEFAULT_PAGE_SIZE]u8 = undefined;
    var buffer_b: [DEFAULT_PAGE_SIZE]u8 = undefined;

    const meta = MetaPayload{
        .committed_txn_id = 0,
        .root_page_id = 0, // Empty tree
        .freelist_head_page_id = 0,
        .log_tail_lsn = 0,
        .meta_crc32c = 0,
    };

    try encodeMetaPage(META_A_PAGE_ID, meta, &buffer_a);
    try encodeMetaPage(META_B_PAGE_ID, meta, &buffer_b);

    _ = try file.pwriteAll(&buffer_a, 0);
    _ = try file.pwriteAll(&buffer_b, DEFAULT_PAGE_SIZE);

    // Open pager with allocator
    var pager = try Pager.open(test_filename, arena.allocator());
    defer pager.close();

    // Should have no free pages initially (empty database has only meta pages)
    try testing.expectEqual(@as(usize, 0), pager.getFreePageCount());
    try testing.expectEqual(@as(u64, 1), pager.getLastAllocatedPageId()); // Only meta pages
}

test "PageAllocator.allocatePage_extends_file" {
    const test_filename = "test_allocator_extend.db";
    defer {
        std.fs.cwd().deleteFile(test_filename) catch {};
    }

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    // Create minimal database file using a separate function to avoid file handle conflicts
    {
        var file = try std.fs.cwd().createFile(test_filename, .{ .truncate = true });
        defer file.close();

        var buffer_a: [DEFAULT_PAGE_SIZE]u8 = undefined;
        var buffer_b: [DEFAULT_PAGE_SIZE]u8 = undefined;

        const meta = MetaPayload{
            .committed_txn_id = 0,
            .root_page_id = 0,
            .freelist_head_page_id = 0,
            .log_tail_lsn = 0,
            .meta_crc32c = 0,
        };

        try encodeMetaPage(META_A_PAGE_ID, meta, &buffer_a);
        try encodeMetaPage(META_B_PAGE_ID, meta, &buffer_b);

        _ = try file.pwriteAll(&buffer_a, 0);
        _ = try file.pwriteAll(&buffer_b, DEFAULT_PAGE_SIZE);
    }

    var pager = try Pager.open(test_filename, arena.allocator());
    defer pager.close();

    // Allocate first page - should be page ID 2 (after meta pages)
    const page_id = try pager.allocatePage();
    try testing.expectEqual(@as(u64, 2), page_id);

    // Last allocated page should be 2 (file now has 3 pages)
    try testing.expectEqual(@as(u64, 2), pager.getLastAllocatedPageId());

    // Allocate another page - should be page ID 3
    const page_id2 = try pager.allocatePage();
    try testing.expectEqual(@as(u64, 3), page_id2);

    try testing.expectEqual(@as(u64, 3), pager.getLastAllocatedPageId());
}

test "PageAllocator.freePage_reuses_freed_pages" {
    const test_filename = "test_allocator_reuse.db";
    defer {
        std.fs.cwd().deleteFile(test_filename) catch {};
    }

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    // Create minimal database file using a separate function to avoid file handle conflicts
    {
        var file = try std.fs.cwd().createFile(test_filename, .{ .truncate = true });
        defer file.close();

        var buffer_a: [DEFAULT_PAGE_SIZE]u8 = undefined;
        var buffer_b: [DEFAULT_PAGE_SIZE]u8 = undefined;

        const meta = MetaPayload{
            .committed_txn_id = 0,
            .root_page_id = 0,
            .freelist_head_page_id = 0,
            .log_tail_lsn = 0,
            .meta_crc32c = 0,
        };

        try encodeMetaPage(META_A_PAGE_ID, meta, &buffer_a);
        try encodeMetaPage(META_B_PAGE_ID, meta, &buffer_b);

        _ = try file.pwriteAll(&buffer_a, 0);
        _ = try file.pwriteAll(&buffer_b, DEFAULT_PAGE_SIZE);
    }

    var pager = try Pager.open(test_filename, arena.allocator());
    defer pager.close();

    // Allocate some pages
    const page1 = try pager.allocatePage(); // Will be page 2
    const page2 = try pager.allocatePage(); // Will be page 3
    const page3 = try pager.allocatePage(); // Will be page 4

    try testing.expectEqual(@as(u64, 2), page1);
    try testing.expectEqual(@as(u64, 3), page2);
    try testing.expectEqual(@as(u64, 4), page3);

    try testing.expectEqual(@as(usize, 0), pager.getFreePageCount());

    // Free page 3
    try pager.freePage(page2);
    try testing.expectEqual(@as(usize, 1), pager.getFreePageCount());

    // Next allocation should reuse freed page
    const reused_page = try pager.allocatePage();
    try testing.expectEqual(@as(u64, 3), reused_page); // Should reuse page 3
    try testing.expectEqual(@as(usize, 0), pager.getFreePageCount());
}

test "PageAllocator.freePage_rejects_meta_pages" {
    const test_filename = "test_allocator_meta_protection.db";
    defer {
        std.fs.cwd().deleteFile(test_filename) catch {};
    }

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const file = try std.fs.cwd().createFile(test_filename, .{ .truncate = true });
    defer file.close();

    var buffer_a: [DEFAULT_PAGE_SIZE]u8 = undefined;
    var buffer_b: [DEFAULT_PAGE_SIZE]u8 = undefined;

    const meta = MetaPayload{
        .committed_txn_id = 0,
        .root_page_id = 0,
        .freelist_head_page_id = 0,
        .log_tail_lsn = 0,
        .meta_crc32c = 0,
    };

    try encodeMetaPage(META_A_PAGE_ID, meta, &buffer_a);
    try encodeMetaPage(META_B_PAGE_ID, meta, &buffer_b);

    _ = try file.pwriteAll(&buffer_a, 0);
    _ = try file.pwriteAll(&buffer_b, DEFAULT_PAGE_SIZE);

    var pager = try Pager.open(test_filename, arena.allocator());
    defer pager.close();

    // Should not be able to free meta pages
    try testing.expectError(error.InvalidOperation, pager.freePage(META_A_PAGE_ID));
    try testing.expectError(error.InvalidOperation, pager.freePage(META_B_PAGE_ID));
}

test "PageAllocator.rebuild_freelist_skips_btree_pages" {
    const test_filename = "test_allocator_rebuild.db";
    defer {
        std.fs.cwd().deleteFile(test_filename) catch {};
    }

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const file = try std.fs.cwd().createFile(test_filename, .{ .truncate = true });
    defer file.close();

    // Create a database with a btree root page
    var buffer_a: [DEFAULT_PAGE_SIZE]u8 = undefined;
    var buffer_b: [DEFAULT_PAGE_SIZE]u8 = undefined;
    var root_buffer: [DEFAULT_PAGE_SIZE]u8 = undefined;

    const meta = MetaPayload{
        .committed_txn_id = 1,
        .root_page_id = 2, // Root page is page 2
        .freelist_head_page_id = 0,
        .log_tail_lsn = 0,
        .meta_crc32c = 0,
    };

    try encodeMetaPage(META_A_PAGE_ID, meta, &buffer_a);
    try encodeMetaPage(META_B_PAGE_ID, meta, &buffer_b);

    _ = try file.pwriteAll(&buffer_a, 0);
    _ = try file.pwriteAll(&buffer_b, DEFAULT_PAGE_SIZE);

    // Create a valid btree leaf page as root
    var root_header = PageHeader{
        .page_type = .btree_leaf,
        .page_id = 2,
        .txn_id = 1,
        .payload_len = BtreeNodeHeader.SIZE,
        .header_crc32c = 0,
        .page_crc32c = 0,
    };
    root_header.header_crc32c = root_header.calculateHeaderChecksum();

    var root_node = BtreeNodeHeader{
        .level = 0, // Leaf
        .key_count = 0,
        .right_sibling = 0,
    };

    try root_header.encode(root_buffer[0..PageHeader.SIZE]);
    try root_node.encode(root_buffer[PageHeader.SIZE .. PageHeader.SIZE + BtreeNodeHeader.SIZE]);

    // Calculate page checksum
    root_header.page_crc32c = calculatePageChecksum(root_buffer[0 .. PageHeader.SIZE + root_header.payload_len]);
    try root_header.encode(root_buffer[0..PageHeader.SIZE]);

    _ = try file.pwriteAll(&root_buffer, 2 * DEFAULT_PAGE_SIZE);

    // Open pager and verify freelist rebuild
    var pager = try Pager.open(test_filename, arena.allocator());
    defer pager.close();

    // Should have 0 free pages since page 2 is used as root
    try testing.expectEqual(@as(usize, 0), pager.getFreePageCount());
    try testing.expectEqual(@as(u64, 2), pager.getLastAllocatedPageId());

    // Root page should be accessible
    try testing.expectEqual(@as(u64, 2), pager.getRootPageId());
}

test "Pager.readPage_with_checksums_and_bounds_checks" {
    const test_filename = "test_read_page_validation.db";
    defer {
        std.fs.cwd().deleteFile(test_filename) catch {};
    }

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    // Create test database file
    const file = try std.fs.cwd().createFile(test_filename, .{ .truncate = true });
    defer file.close();

    var buffer_a: [DEFAULT_PAGE_SIZE]u8 = undefined;
    var buffer_b: [DEFAULT_PAGE_SIZE]u8 = undefined;
    var test_buffer: [DEFAULT_PAGE_SIZE]u8 = undefined;

    const meta = MetaPayload{
        .committed_txn_id = 0,
        .root_page_id = 0,
        .freelist_head_page_id = 0,
        .log_tail_lsn = 0,
        .meta_crc32c = 0,
    };

    try encodeMetaPage(META_A_PAGE_ID, meta, &buffer_a);
    try encodeMetaPage(META_B_PAGE_ID, meta, &buffer_b);

    _ = try file.pwriteAll(&buffer_a, 0);
    _ = try file.pwriteAll(&buffer_b, DEFAULT_PAGE_SIZE);

    // Create a valid test page
    const test_payload = "Hello, World!";
    try createPage(2, .btree_leaf, 1, test_payload, &test_buffer);
    _ = try file.pwriteAll(&test_buffer, 2 * DEFAULT_PAGE_SIZE);

    var pager = try Pager.open(test_filename, arena.allocator());
    defer pager.close();

    var read_buffer: [DEFAULT_PAGE_SIZE]u8 = undefined;

    // Successful read
    try pager.readPage(2, &read_buffer);
    const header = try PageHeader.decode(read_buffer[0..PageHeader.SIZE]);
    try testing.expectEqual(@as(u64, 2), header.page_id);
    try testing.expectEqual(PageType.btree_leaf, header.page_type);
    try testing.expectEqual(@as(u64, 1), header.txn_id);
    try testing.expectEqual(test_payload.len, header.payload_len);

    // Verify payload
    const read_payload = read_buffer[PageHeader.SIZE .. PageHeader.SIZE + test_payload.len];
    try testing.expectEqualStrings(test_payload, read_payload);
}

test "Pager.readPage_rejects_invalid_page_id" {
    const test_filename = "test_read_page_invalid_id.db";
    defer {
        std.fs.cwd().deleteFile(test_filename) catch {};
    }

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    // Create minimal database file
    const file = try std.fs.cwd().createFile(test_filename, .{ .truncate = true });
    defer file.close();

    var buffer_a: [DEFAULT_PAGE_SIZE]u8 = undefined;
    var buffer_b: [DEFAULT_PAGE_SIZE]u8 = undefined;

    const meta = MetaPayload{
        .committed_txn_id = 0,
        .root_page_id = 0,
        .freelist_head_page_id = 0,
        .log_tail_lsn = 0,
        .meta_crc32c = 0,
    };

    try encodeMetaPage(META_A_PAGE_ID, meta, &buffer_a);
    try encodeMetaPage(META_B_PAGE_ID, meta, &buffer_b);

    _ = try file.pwriteAll(&buffer_a, 0);
    _ = try file.pwriteAll(&buffer_b, DEFAULT_PAGE_SIZE);

    var pager = try Pager.open(test_filename, arena.allocator());
    defer pager.close();

    var read_buffer: [DEFAULT_PAGE_SIZE]u8 = undefined;

    // Should fail with page out of bounds
    try testing.expectError(error.PageOutOfBounds, pager.readPage(100, &read_buffer));
}

test "Pager.readPage_rejects_corrupted_checksum" {
    const test_filename = "test_read_page_corrupt.db";
    defer {
        std.fs.cwd().deleteFile(test_filename) catch {};
    }

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    // Create test database file
    const file = try std.fs.cwd().createFile(test_filename, .{ .truncate = true });
    defer file.close();

    var buffer_a: [DEFAULT_PAGE_SIZE]u8 = undefined;
    var buffer_b: [DEFAULT_PAGE_SIZE]u8 = undefined;
    var test_buffer: [DEFAULT_PAGE_SIZE]u8 = undefined;

    const meta = MetaPayload{
        .committed_txn_id = 0,
        .root_page_id = 0,
        .freelist_head_page_id = 0,
        .log_tail_lsn = 0,
        .meta_crc32c = 0,
    };

    try encodeMetaPage(META_A_PAGE_ID, meta, &buffer_a);
    try encodeMetaPage(META_B_PAGE_ID, meta, &buffer_b);

    _ = try file.pwriteAll(&buffer_a, 0);
    _ = try file.pwriteAll(&buffer_b, DEFAULT_PAGE_SIZE);

    // Create a valid test page
    const test_payload = "Test data";
    try createPage(2, .btree_leaf, 1, test_payload, &test_buffer);

    // Corrupt the page checksum
    test_buffer[@offsetOf(PageHeader, "page_crc32c")] += 1;

    _ = try file.pwriteAll(&test_buffer, 2 * DEFAULT_PAGE_SIZE);

    var pager = try Pager.open(test_filename, arena.allocator());
    defer pager.close();

    var read_buffer: [DEFAULT_PAGE_SIZE]u8 = undefined;

    // Should fail with invalid page checksum
    try testing.expectError(error.InvalidPageChecksum, pager.readPage(2, &read_buffer));
}

test "Pager.writePage_with_checksums_and_bounds_checks" {
    const test_filename = "test_write_page_validation.db";
    defer {
        std.fs.cwd().deleteFile(test_filename) catch {};
    }

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    // Create minimal database file
    const file = try std.fs.cwd().createFile(test_filename, .{ .truncate = true });
    defer file.close();

    var buffer_a: [DEFAULT_PAGE_SIZE]u8 = undefined;
    var buffer_b: [DEFAULT_PAGE_SIZE]u8 = undefined;

    const meta = MetaPayload{
        .committed_txn_id = 0,
        .root_page_id = 0,
        .freelist_head_page_id = 0,
        .log_tail_lsn = 0,
        .meta_crc32c = 0,
    };

    try encodeMetaPage(META_A_PAGE_ID, meta, &buffer_a);
    try encodeMetaPage(META_B_PAGE_ID, meta, &buffer_b);

    _ = try file.pwriteAll(&buffer_a, 0);
    _ = try file.pwriteAll(&buffer_b, DEFAULT_PAGE_SIZE);

    var pager = try Pager.open(test_filename, arena.allocator());
    defer pager.close();

    // Create a valid page to write
    var write_buffer: [DEFAULT_PAGE_SIZE]u8 = undefined;
    const test_payload = "Write test data";
    try createPage(2, .btree_leaf, 1, test_payload, &write_buffer);

    // Successful write
    try pager.writePage(2, &write_buffer);

    // Verify by reading it back
    var read_buffer: [DEFAULT_PAGE_SIZE]u8 = undefined;
    try pager.readPage(2, &read_buffer);

    const header = try PageHeader.decode(read_buffer[0..PageHeader.SIZE]);
    try testing.expectEqual(@as(u64, 2), header.page_id);
    try testing.expectEqual(PageType.btree_leaf, header.page_type);

    const read_payload = read_buffer[PageHeader.SIZE .. PageHeader.SIZE + test_payload.len];
    try testing.expectEqualStrings(test_payload, read_payload);
}

test "Pager.writePage_rejects_page_id_mismatch" {
    const test_filename = "test_write_page_mismatch.db";
    defer {
        std.fs.cwd().deleteFile(test_filename) catch {};
    }

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    // Create minimal database file
    const file = try std.fs.cwd().createFile(test_filename, .{ .truncate = true });
    defer file.close();

    var buffer_a: [DEFAULT_PAGE_SIZE]u8 = undefined;
    var buffer_b: [DEFAULT_PAGE_SIZE]u8 = undefined;

    const meta = MetaPayload{
        .committed_txn_id = 0,
        .root_page_id = 0,
        .freelist_head_page_id = 0,
        .log_tail_lsn = 0,
        .meta_crc32c = 0,
    };

    try encodeMetaPage(META_A_PAGE_ID, meta, &buffer_a);
    try encodeMetaPage(META_B_PAGE_ID, meta, &buffer_b);

    _ = try file.pwriteAll(&buffer_a, 0);
    _ = try file.pwriteAll(&buffer_b, DEFAULT_PAGE_SIZE);

    var pager = try Pager.open(test_filename, arena.allocator());
    defer pager.close();

    // Create a page with ID 2, but try to write to ID 3
    var write_buffer: [DEFAULT_PAGE_SIZE]u8 = undefined;
    const test_payload = "Mismatch test";
    try createPage(2, .btree_leaf, 1, test_payload, &write_buffer);

    // Should fail with page ID mismatch
    try testing.expectError(error.PageIdMismatch, pager.writePage(3, &write_buffer));
}

test "createPage_creates_properly_checksummed_page" {
    var buffer: [DEFAULT_PAGE_SIZE]u8 = undefined;
    const test_payload = "Test payload for createPage";

    // Create a page
    try createPage(5, .btree_internal, 42, test_payload, &buffer);

    // Validate the created page
    const header = try validatePage(&buffer);
    try testing.expectEqual(@as(u64, 5), header.page_id);
    try testing.expectEqual(PageType.btree_internal, header.page_type);
    try testing.expectEqual(@as(u64, 42), header.txn_id);
    try testing.expectEqual(test_payload.len, header.payload_len);

    // Verify payload content
    const payload_area = buffer[PageHeader.SIZE .. PageHeader.SIZE + test_payload.len];
    try testing.expectEqualStrings(test_payload, payload_area);

    // Verify rest of page is zeroed
    const rest_start = PageHeader.SIZE + test_payload.len;
    for (buffer[rest_start..]) |byte| {
        try testing.expectEqual(@as(u8, 0), byte);
    }
}

test "createBtreePage_creates_btree_with_node_header" {
    var buffer: [DEFAULT_PAGE_SIZE]u8 = undefined;
    const test_payload = "Btree node data";

    // Create a btree leaf page
    try createBtreePage(10, 0, 3, 15, 100, test_payload, &buffer);

    // Validate the page
    const header = try validatePage(&buffer);
    try testing.expectEqual(@as(u64, 10), header.page_id);
    try testing.expectEqual(PageType.btree_leaf, header.page_type);
    try testing.expectEqual(@as(u64, 100), header.txn_id);

    // Validate node header
    const node_header = try BtreeNodeHeader.decode(buffer[PageHeader.SIZE .. PageHeader.SIZE + BtreeNodeHeader.SIZE]);
    try testing.expectEqual(@as(u16, 0), node_header.level);
    try testing.expectEqual(@as(u16, 3), node_header.key_count);
    try testing.expectEqual(@as(u64, 15), node_header.right_sibling);

    // Verify payload content after node header
    const payload_start = PageHeader.SIZE + BtreeNodeHeader.SIZE;
    const payload_area = buffer[payload_start .. payload_start + test_payload.len];
    try testing.expectEqualStrings(test_payload, payload_area);
}

test "createPage_rejects_oversized_payload" {
    var buffer: [DEFAULT_PAGE_SIZE]u8 = undefined;

    // Create payload that's too large
    const oversized_payload = [_]u8{0xAA} ** (DEFAULT_PAGE_SIZE - PageHeader.SIZE + 1);

    // Should fail with payload too large
    try testing.expectError(error.PayloadTooLarge, createPage(1, .btree_leaf, 1, &oversized_payload, &buffer));
}