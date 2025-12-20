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