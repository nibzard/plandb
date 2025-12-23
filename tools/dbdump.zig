//! Database dump utility for NorthstarDB.
//!
//! This tool inspects and validates database files.
//! It can decode page structure, dump B+tree contents, validate invariants,
//! and export data for analysis.

const std = @import("std");
const pager = @import("pager");

const Command = enum {
    dump,
    validate,
    stats,
    @"export",
    help,
};

const ExportFormat = enum {
    csv,
    json,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        try printUsage();
        return error.InvalidArguments;
    }

    const command = parseCommand(args[1]) catch {
        try printUsage();
        return error.InvalidCommand;
    };

    switch (command) {
        .help => {
            try printUsage();
            return;
        },
        .dump => {
            if (args.len < 3) {
                std.log.err("Error: dump command requires a database file path", .{});
                return error.MissingArgument;
            }
            try dumpDatabase(args[2], allocator);
        },
        .validate => {
            if (args.len < 3) {
                std.log.err("Error: validate command requires a database file path", .{});
                return error.MissingArgument;
            }
            const exit_code = try validateDatabase(args[2], allocator);
            std.process.exit(exit_code);
        },
        .stats => {
            if (args.len < 3) {
                std.log.err("Error: stats command requires a database file path", .{});
                return error.MissingArgument;
            }
            try showStats(args[2], allocator);
        },
        .@"export" => {
            if (args.len < 4) {
                std.log.err("Error: export command requires database file and format (csv|json)", .{});
                return error.MissingArgument;
            }
            const format = parseExportFormat(args[3]) catch {
                std.log.err("Error: invalid export format '{s}'. Use csv or json", .{args[3]});
                return error.InvalidExportFormat;
            };
            try exportDatabase(args[2], format, allocator);
        },
    }
}

fn parseCommand(arg: []const u8) !Command {
    if (std.mem.eql(u8, arg, "dump")) return .dump;
    if (std.mem.eql(u8, arg, "validate")) return .validate;
    if (std.mem.eql(u8, arg, "stats")) return .stats;
    if (std.mem.eql(u8, arg, "export")) return .@"export";
    if (std.mem.eql(u8, arg, "help") or std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) return .help;
    return error.UnknownCommand;
}

fn parseExportFormat(arg: []const u8) !ExportFormat {
    if (std.mem.eql(u8, arg, "csv")) return .csv;
    if (std.mem.eql(u8, arg, "json")) return .json;
    return error.UnknownFormat;
}

fn printUsage() !void {
    std.debug.print(
        \\NorthstarDB Database Inspection Tool
        \\
        \\Usage: dbdump <command> <database_file> [options]
        \\
        \\Commands:
        \\  dump <file>         - Decode and display database structure and contents
        \\  validate <file>     - Validate database integrity and invariants
        \\  stats <file>        - Show database statistics and metrics
        \\  export <file> <fmt> - Export key-value pairs (fmt: csv|json)
        \\  help                - Show this help message
        \\
        \\Examples:
        \\  dbdump dump test.db
        \\  dbdump validate test.db
        \\  dbdump stats test.db
        \\  dbdump export test.db csv > output.csv
        \\
    , .{});
}

// DatabaseInspector wraps a file for read-only inspection
const DatabaseInspector = struct {
    file: std.fs.File,
    page_size: u16,
    file_size: u64,
    meta: ?pager.MetaState,

    const Self = @This();

    pub fn open(path: []const u8) !Self {
        const file = try std.fs.cwd().openFile(path, .{ .mode = .read_only });
        const file_size = try file.getEndPos();

        if (file_size < pager.DEFAULT_PAGE_SIZE * 2) {
            return error.FileTooSmall;
        }

        // Read both meta pages
        var buffer_a: [pager.DEFAULT_PAGE_SIZE]u8 = undefined;
        var buffer_b: [pager.DEFAULT_PAGE_SIZE]u8 = undefined;

        _ = try file.preadAll(&buffer_a, 0);
        _ = try file.preadAll(&buffer_b, pager.DEFAULT_PAGE_SIZE);

        // Try to decode both meta pages
        const meta_a_result = pager.decodeMetaPage(&buffer_a, pager.META_A_PAGE_ID);
        const meta_a = meta_a_result catch |err| switch (err) {
            error.InvalidHeaderChecksum, error.InvalidMetaChecksum, error.InvalidMagic, error.InvalidMetaMagic, error.InvalidPageType, error.UnexpectedPageId => null,
            else => return err,
        };

        const meta_b = pager.decodeMetaPage(&buffer_b, pager.META_B_PAGE_ID) catch |err| switch (err) {
            error.InvalidHeaderChecksum, error.InvalidMetaChecksum, error.InvalidMagic, error.InvalidMetaMagic, error.InvalidPageType, error.UnexpectedPageId => null,
            else => return err,
        };

        // Choose best meta
        const best_meta = chooseBestMeta(meta_a, meta_b);

        return Self{
            .file = file,
            .page_size = if (best_meta) |m| m.meta.page_size else pager.DEFAULT_PAGE_SIZE,
            .file_size = @intCast(file_size),
            .meta = best_meta,
        };
    }

    pub fn close(self: Self) void {
        self.file.close();
    }

    pub fn readPage(self: Self, allocator: std.mem.Allocator, page_id: u64) ![]const u8 {
        const offset = page_id * self.page_size;
        if (offset + self.page_size > self.file_size) {
            return error.PageOutOfBounds;
        }

        var buffer: [pager.DEFAULT_PAGE_SIZE]u8 = undefined;
        const bytes_read = try self.file.preadAll(&buffer, offset);
        if (bytes_read != self.page_size) {
            return error.IncompletePage;
        }

        const page_data = try allocator.alloc(u8, self.page_size);
        @memcpy(page_data, &buffer);
        return page_data;
    }

    pub fn getPageCount(self: Self) u64 {
        return self.file_size / self.page_size;
    }
};

fn chooseBestMeta(meta_a: ?pager.MetaState, meta_b: ?pager.MetaState) ?pager.MetaState {
    if (meta_a == null and meta_b == null) return null;

    if (meta_a == null) return meta_b;
    if (meta_b == null) return meta_a;

    // Both valid - choose highest txn_id
    if (meta_a.?.meta.committed_txn_id > meta_b.?.meta.committed_txn_id) {
        return meta_a;
    } else {
        return meta_b;
    }
}

fn dumpDatabase(path: []const u8, allocator: std.mem.Allocator) !void {
    var inspector = try DatabaseInspector.open(path);
    defer inspector.close();

    std.log.info("Database: {s} ({} bytes, {} pages)", .{ path, inspector.file_size, inspector.getPageCount() });
    std.log.info("=" ** 70, .{});

    // Dump meta info
    if (inspector.meta) |meta| {
        std.log.info("Meta Information:", .{});
        std.log.info("  Format Version: {d}", .{meta.meta.format_version});
        std.log.info("  Page Size: {d} bytes", .{meta.meta.page_size});
        std.log.info("  Committed TxnId: {d}", .{meta.meta.committed_txn_id});
        std.log.info("  Root Page ID: {d}", .{meta.meta.root_page_id});
        std.log.info("  Freelist Head: {d}", .{meta.meta.freelist_head_page_id});
        std.log.info("  Log Tail LSN: {d}", .{meta.meta.log_tail_lsn});
        std.log.info("", .{});
    } else {
        std.log.err("Warning: No valid meta pages found", .{});
        return error.CorruptMeta;
    }

    const root_page_id = inspector.meta.?.meta.root_page_id;
    if (root_page_id == 0) {
        std.log.info("Database is empty (no root page)", .{});
        return;
    }

    // Recursively dump tree structure
    try dumpTree(&inspector, root_page_id, 0, allocator);
}

fn dumpTree(inspector: *DatabaseInspector, page_id: u64, depth: usize, allocator: std.mem.Allocator) !void {
    const page_data = try inspector.readPage(allocator, page_id);
    defer allocator.free(page_data);

    const header = try pager.PageHeader.decode(page_data);

    // Print indentation
    var indent_buf: [64]u8 = undefined;
    if (depth > 0) {
        @memset(indent_buf[0..depth * 2], ' ');
    }

    // Use separate prints for depth 0 vs depth > 0 to avoid type issues
    if (depth == 0) {
        std.debug.print("Page {d}: type={s}, txn_id={d}\n", .{
            page_id,
            switch (header.page_type) {
                .meta => "meta",
                .btree_internal => "internal",
                .btree_leaf => "leaf",
                .freelist => "freelist",
                .log_segment => "log_segment",
            },
            header.txn_id,
        });
    } else {
        std.debug.print("{s}Page {d}: type={s}, txn_id={d}\n", .{
            indent_buf[0..depth * 2],
            page_id,
            switch (header.page_type) {
                .meta => "meta",
                .btree_internal => "internal",
                .btree_leaf => "leaf",
                .freelist => "freelist",
                .log_segment => "log_segment",
            },
            header.txn_id,
        });
    }

    switch (header.page_type) {
        .btree_leaf => {
            const node_header = try pager.BtreeNodeHeader.decode(page_data[pager.PageHeader.SIZE..]);
            if (depth == 0) {
                std.debug.print("  Level: {d}, Keys: {d}, Right Sibling: {d}\n", .{
                    node_header.level,
                    node_header.key_count,
                    node_header.right_sibling,
                });
            } else {
                std.debug.print("{s}  Level: {d}, Keys: {d}, Right Sibling: {d}\n", .{
                    indent_buf[0..depth * 2],
                    node_header.level,
                    node_header.key_count,
                    node_header.right_sibling,
                });
            }

            // Dump entries
            var i: u16 = 0;
            while (i < node_header.key_count) : (i += 1) {
                const leaf = pager.BtreeLeafPayload{};
                const entry = leaf.getEntry(page_data[pager.PageHeader.SIZE..], i) catch continue;

                const max_display = @min(entry.key.len, 40);
                const is_binary = !std.unicode.utf8ValidateSlice(entry.key[0..max_display]);

                _ = @min(entry.value.len, 30);
                const has_suffix = entry.key.len > 40;
                if (is_binary) {
                    if (depth == 0) {
                        if (has_suffix) {
                            std.debug.print("    [{d}] key=\"(binary)\"... val_len={d}\n", .{
                                i,
                                entry.value.len,
                            });
                        } else {
                            std.debug.print("    [{d}] key=\"(binary)\" val_len={d}\n", .{
                                i,
                                entry.value.len,
                            });
                        }
                    } else {
                        if (has_suffix) {
                            std.debug.print("{s}    [{d}] key=\"(binary)\"... val_len={d}\n", .{
                                indent_buf[0..depth * 2],
                                i,
                                entry.value.len,
                            });
                        } else {
                            std.debug.print("{s}    [{d}] key=\"(binary)\" val_len={d}\n", .{
                                indent_buf[0..depth * 2],
                                i,
                                entry.value.len,
                            });
                        }
                    }
                } else {
                    if (depth == 0) {
                        if (has_suffix) {
                            std.debug.print("    [{d}] key=\"{s}\"... val_len={d}\n", .{
                                i,
                                entry.key[0..max_display],
                                entry.value.len,
                            });
                        } else {
                            std.debug.print("    [{d}] key=\"{s}\" val_len={d}\n", .{
                                i,
                                entry.key[0..max_display],
                                entry.value.len,
                            });
                        }
                    } else {
                        if (has_suffix) {
                            std.debug.print("{s}    [{d}] key=\"{s}\"... val_len={d}\n", .{
                                indent_buf[0..depth * 2],
                                i,
                                entry.key[0..max_display],
                                entry.value.len,
                            });
                        } else {
                            std.debug.print("{s}    [{d}] key=\"{s}\" val_len={d}\n", .{
                                indent_buf[0..depth * 2],
                                i,
                                entry.key[0..max_display],
                                entry.value.len,
                            });
                        }
                    }
                }
            }
        },
        .btree_internal => {
            const node_header = try pager.BtreeNodeHeader.decode(page_data[pager.PageHeader.SIZE..]);
            if (depth == 0) {
                std.debug.print("  Level: {d}, Keys: {d}\n", .{
                    node_header.level,
                    node_header.key_count
                });
            } else {
                std.debug.print("{s}  Level: {d}, Keys: {d}\n", .{
                    indent_buf[0..depth * 2],
                    node_header.level,
                    node_header.key_count
                });
            }

            // Recurse into children
            var i: u16 = 0;
            while (i <= node_header.key_count) : (i += 1) {
                const internal = pager.BtreeInternalPayload{};
                const child_id = internal.getChildPageId(page_data[pager.PageHeader.SIZE..], i) catch continue;
                if (child_id != 0) {
                    try dumpTree(inspector, child_id, depth + 1, allocator);
                }
            }
        },
        else => {},
    }
}

fn validateDatabase(path: []const u8, allocator: std.mem.Allocator) !u8 {
    var inspector = try DatabaseInspector.open(path);
    defer inspector.close();

    std.log.info("Validating database: {s}", .{path});

    var errors: usize = 0;
    const warnings: usize = 0;

    // Validate meta pages
    if (inspector.meta) |meta| {
        std.log.info("Meta validation: OK (txn_id={d})", .{meta.meta.committed_txn_id});
    } else {
        std.log.err("Meta validation: FAILED - no valid meta pages", .{});
        errors += 1;
    }

    if (inspector.meta == null) {
        std.log.info("Result: FAILED ({d} errors)", .{errors});
        return 1;
    }

    const root_page_id = inspector.meta.?.meta.root_page_id;
    if (root_page_id == 0) {
        std.log.info("Tree validation: SKIPPED (empty database)", .{});
    } else {
        // Validate tree structure
        const tree_errors = try validateTree(&inspector, root_page_id, allocator);
        errors += tree_errors;
    }

    // Validate page count
    const page_count = inspector.getPageCount();
    std.log.info("Page count: {d}", .{page_count});

    std.log.info("Validation complete: {d} errors, {d} warnings", .{ errors, warnings });

    if (errors == 0) {
        std.log.info("Result: PASSED", .{});
        return 0;
    } else {
        std.log.info("Result: FAILED", .{});
        return 1;
    }
}

fn validateTree(inspector: *DatabaseInspector, page_id: u64, allocator: std.mem.Allocator) !usize {
    var errors: usize = 0;
    const page_data = try inspector.readPage(allocator, page_id);
    defer allocator.free(page_data);

    const header = pager.PageHeader.decode(page_data) catch |err| {
        std.log.err("Page {d}: Invalid header - {}", .{ page_id, err });
        return 1;
    };

    // Validate header checksum
    if (!header.validateHeaderChecksum()) {
        std.log.err("Page {d}: Header checksum mismatch", .{page_id});
        errors += 1;
    }

    // Validate page checksum
    const payload = page_data[pager.PageHeader.SIZE..];
    var hasher = std.hash.Crc32.init();
    hasher.update(payload);
    const calculated_crc = hasher.final();
    if (calculated_crc != header.page_crc32c) {
        std.log.err("Page {d}: Page checksum mismatch (expected 0x{x}, got 0x{x})", .{
            page_id, header.page_crc32c, calculated_crc
        });
        errors += 1;
    }

    switch (header.page_type) {
        .btree_leaf => {
            const leaf = pager.BtreeLeafPayload{};
            leaf.validate(payload) catch |err| {
                std.log.err("Page {d}: Leaf validation failed - {}", .{ page_id, err });
                errors += 1;
            };
        },
        .btree_internal => {
            const node_header = pager.BtreeNodeHeader.decode(payload) catch |err| {
                std.log.err("Page {d}: Invalid node header - {}", .{ page_id, err });
                errors += 1;
                return errors;
            };

            // Recurse into children
            var i: u16 = 0;
            while (i <= node_header.key_count) : (i += 1) {
                const internal = pager.BtreeInternalPayload{};
                const child_id = internal.getChildPageId(payload, i) catch continue;
                if (child_id != 0) {
                    errors += try validateTree(inspector, child_id, allocator);
                }
            }
        },
        else => {},
    }

    return errors;
}

fn showStats(path: []const u8, allocator: std.mem.Allocator) !void {
    var inspector = try DatabaseInspector.open(path);
    defer inspector.close();

    std.log.info("Database Statistics: {s}", .{path});
    std.log.info("=" ** 50, .{});

    // Basic stats
    const page_count = inspector.getPageCount();
    std.log.info("File Size: {d} bytes", .{inspector.file_size});
    std.log.info("Page Size: {d} bytes", .{inspector.page_size});
    std.log.info("Total Pages: {d}", .{page_count});

    if (inspector.meta) |meta| {
        std.log.info("Committed TxnId: {d}", .{meta.meta.committed_txn_id});
    }

    const root_page_id = if (inspector.meta) |m| m.meta.root_page_id else 0;
    if (root_page_id == 0) {
        std.log.info("Root Page: none (empty database)", .{});
        return;
    }
    std.log.info("Root Page: {d}", .{root_page_id});

    // Count page types
    var stats = PageStats{};

    var page_id: u64 = 0;
    while (page_id < page_count) : (page_id += 1) {
        const page_data = inspector.readPage(allocator, page_id) catch continue;
        defer allocator.free(page_data);

        const header = pager.PageHeader.decode(page_data) catch continue;

        switch (header.page_type) {
            .meta => stats.meta_pages += 1,
            .btree_leaf => {
                stats.leaf_pages += 1;
                const node_header = pager.BtreeNodeHeader.decode(page_data[pager.PageHeader.SIZE..]) catch continue;
                stats.total_keys += node_header.key_count;
                stats.max_depth = @max(stats.max_depth, node_header.level + 1);
            },
            .btree_internal => stats.internal_pages += 1,
            .freelist => stats.freelist_pages += 1,
            .log_segment => stats.log_pages += 1,
        }
    }

    std.log.info("", .{});
    std.log.info("Page Distribution:", .{});
    std.log.info("  Meta pages: {d}", .{stats.meta_pages});
    std.log.info("  Internal pages: {d}", .{stats.internal_pages});
    std.log.info("  Leaf pages: {d}", .{stats.leaf_pages});
    std.log.info("  Freelist pages: {d}", .{stats.freelist_pages});
    std.log.info("  Log pages: {d}", .{stats.log_pages});
    std.log.info("", .{});
    std.log.info("Tree Statistics:", .{});
    std.log.info("  Total keys: {d}", .{stats.total_keys});
    std.log.info("  Max depth: {d}", .{stats.max_depth});
}

const PageStats = struct {
    meta_pages: u64 = 0,
    internal_pages: u64 = 0,
    leaf_pages: u64 = 0,
    freelist_pages: u64 = 0,
    log_pages: u64 = 0,
    total_keys: u64 = 0,
    max_depth: u16 = 0,
};

fn exportDatabase(path: []const u8, format: ExportFormat, allocator: std.mem.Allocator) !void {
    var inspector = try DatabaseInspector.open(path);
    defer inspector.close();

    const root_page_id = if (inspector.meta) |m| m.meta.root_page_id else 0;
    if (root_page_id == 0) {
        std.log.err("Database is empty", .{});
        return error.EmptyDatabase;
    }

    switch (format) {
        .csv => {
            std.debug.print("key,value\n", .{});
            try exportTreeCsv(&inspector, root_page_id, allocator);
        },
        .json => {
            try exportTreeJson(&inspector, root_page_id, allocator);
        },
    }
}

fn exportTreeCsv(inspector: *DatabaseInspector, page_id: u64, allocator: std.mem.Allocator) !void {
    const page_data = try inspector.readPage(allocator, page_id);
    defer allocator.free(page_data);

    const header = try pager.PageHeader.decode(page_data);

    if (header.page_type == .btree_leaf) {
        const leaf = pager.BtreeLeafPayload{};
        var i: u16 = 0;
        while (i < 200) : (i += 1) { // MAX_KEYS_PER_LEAF
            const entry = leaf.getEntry(page_data[pager.PageHeader.SIZE..], i) catch break;
            try exportEntryCsv(entry);
        }
    } else if (header.page_type == .btree_internal) {
        const node_header = try pager.BtreeNodeHeader.decode(page_data[pager.PageHeader.SIZE..]);
        var i: u16 = 0;
        while (i <= node_header.key_count) : (i += 1) {
            const internal = pager.BtreeInternalPayload{};
            const child_id = internal.getChildPageId(page_data[pager.PageHeader.SIZE..], i) catch continue;
            if (child_id != 0) {
                try exportTreeCsv(inspector, child_id, allocator);
            }
        }
    }
}

fn exportEntryCsv(entry: pager.BtreeLeafEntry) !void {
    // Escape key and value for CSV
    try csvWriteString(entry.key);
    std.debug.print(",", .{});
    try csvWriteString(entry.value);
    std.debug.print("\n", .{});
}

fn csvWriteString(data: []const u8) !void {
    if (std.mem.indexOfScalar(u8, data, '"') != null or std.mem.indexOfScalar(u8, data, ',') != null or std.mem.indexOfScalar(u8, data, '\n') != null) {
        std.debug.print("\"", .{});
        for (data) |c| {
            if (c == '"') std.debug.print("\"\"", .{}) else std.debug.print("{c}", .{c});
        }
        std.debug.print("\"", .{});
    } else {
        std.debug.print("{s}", .{data});
    }
}

fn exportTreeJson(inspector: *DatabaseInspector, page_id: u64, allocator: std.mem.Allocator) !void {
    std.debug.print("[\n", .{});
    var first: bool = true;
    try exportJsonRecursive(inspector, page_id, &first, allocator);
    std.debug.print("\n]\n", .{});
}

fn exportJsonRecursive(inspector: *DatabaseInspector, page_id: u64, first: *bool, allocator: std.mem.Allocator) !void {
    const page_data = try inspector.readPage(allocator, page_id);
    defer allocator.free(page_data);

    const header = try pager.PageHeader.decode(page_data);

    if (header.page_type == .btree_leaf) {
        const leaf = pager.BtreeLeafPayload{};
        var i: u16 = 0;
        while (i < 200) : (i += 1) {
            const entry = leaf.getEntry(page_data[pager.PageHeader.SIZE..], i) catch break;
            if (!first.*) std.debug.print(",\n", .{}) else first.* = false;
            std.debug.print("  {{\"key\": ", .{});
            try jsonWriteString(entry.key);
            std.debug.print(", \"value\": ", .{});
            try jsonWriteString(entry.value);
            std.debug.print("}}", .{});
        }
    } else if (header.page_type == .btree_internal) {
        const node_header = try pager.BtreeNodeHeader.decode(page_data[pager.PageHeader.SIZE..]);
        var i: u16 = 0;
        while (i <= node_header.key_count) : (i += 1) {
            const internal = pager.BtreeInternalPayload{};
            const child_id = internal.getChildPageId(page_data[pager.PageHeader.SIZE..], i) catch continue;
            if (child_id != 0) {
                try exportJsonRecursive(inspector, child_id, first, allocator);
            }
        }
    }
}

fn jsonWriteString(data: []const u8) !void {
    std.debug.print("\"", .{});
    for (data) |c| {
        switch (c) {
            '\\' => std.debug.print("\\\\", .{}),
            '"' => std.debug.print("\\\"", .{}),
            '\n' => std.debug.print("\\n", .{}),
            '\r' => std.debug.print("\\r", .{}),
            '\t' => std.debug.print("\\t", .{}),
            else => {
                if (c < 32) {
                    std.debug.print("\\u00{0x:0>2}", .{c});
                } else {
                    std.debug.print("{c}", .{c});
                }
            },
        }
    }
    std.debug.print("\"", .{});
}
