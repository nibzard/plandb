//! Pending Tasks by Type Cartridge Implementation
//!
//! Provides fast lookup of pending tasks grouped by type for efficient
//! task queue operations as specified in spec/cartridge_format_v1.md

const std = @import("std");
const ArrayListManaged = std.array_list.Managed;
const format = @import("format.zig");
const txn = @import("../txn.zig");
const wal = @import("../wal.zig");
const pager = @import("../pager.zig");

/// Task offset reference
pub const TaskOffset = struct {
    offset: u64,
    size: u64,
};

/// Task entry in the cartridge
pub const CartridgeTaskEntry = struct {
    key: []const u8,
    task_type: []const u8,
    priority: u8,
    claimed: bool,
    claimed_by: ?[]const u8,
    claim_time: ?u64,

    pub fn deinit(self: *CartridgeTaskEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.key);
        allocator.free(self.task_type);
        if (self.claimed_by) |claimed| {
            allocator.free(claimed);
        }
    }
};

/// Type entry in the index
pub const CartridgeTypeEntry = struct {
    task_type: []const u8,
    tasks: ArrayListManaged(TaskOffset),
    first_task_offset: u64,
    last_task_offset: u64,

    pub fn deinit(self: *CartridgeTypeEntry, allocator: std.mem.Allocator) void {
        _ = allocator;
        // Don't free task_type - it's owned by the StringHashMap key
        self.tasks.deinit();
    }
};

/// Compatibility alias for TaskEntry
pub const TaskEntry = CartridgeTaskEntry;
/// Compatibility alias for TypeEntry
pub const TypeEntry = CartridgeTypeEntry;

/// Pending tasks cartridge for fast task queue operations
pub const PendingTasksCartridge = struct {
    allocator: std.mem.Allocator,
    header: format.CartridgeHeader,
    metadata: format.CartridgeMetadata,

    // In-memory indices for fast lookups
    type_index: std.StringHashMap(CartridgeTypeEntry),
    key_index: std.StringHashMap(TaskOffset),

    // Task storage during build (for serialization)
    tasks: ArrayListManaged(CartridgeTaskEntry),

    // Mapped file data (for memory-mapped access)
    mapped_data: ?[]const u8,

    const Self = @This();

    /// Initialize a new pending tasks cartridge for building
    pub fn init(allocator: std.mem.Allocator, source_txn_id: u64) !Self {
        var header = format.CartridgeHeader.init(.pending_tasks_by_type, source_txn_id);
        header.entry_count = 0;
        header.index_offset = format.CartridgeHeader.SIZE;

        var metadata = format.CartridgeMetadata.init("pending_tasks_by_type_v1", allocator);
        metadata.invalidation_policy = try createTaskInvalidationPolicy(allocator);

        const task_list = ArrayListManaged(CartridgeTaskEntry).init(allocator);

        return Self{
            .allocator = allocator,
            .header = header,
            .metadata = metadata,
            .type_index = std.StringHashMap(CartridgeTypeEntry).init(allocator),
            .key_index = std.StringHashMap(TaskOffset).init(allocator),
            .tasks = task_list,
            .mapped_data = null,
        };
    }

    /// Build cartridge from commit log file (offline, deterministic)
    pub fn buildFromLog(allocator: std.mem.Allocator, log_path: []const u8) !Self {
        // Open log file
        var log_file = std.fs.cwd().openFile(log_path, .{ .mode = .read_only }) catch |err| switch (err) {
            error.FileNotFound => {
                // No log file exists, return empty cartridge
                const cartridge = try Self.init(allocator, 0);
                return cartridge;
            },
            else => return err,
        };
        defer log_file.close();

        // Initialize cartridge builder
        var cartridge = try Self.init(allocator, 0);
        errdefer cartridge.deinit();

        // Replay commit records and extract tasks
        var file_pos: usize = 0;
        const file_size = try log_file.getEndPos();

        while (file_pos < file_size) {
            // Read record header
            if (file_pos + wal.WriteAheadLog.RecordHeader.SIZE > file_size) break;

            var header_bytes: [wal.WriteAheadLog.RecordHeader.SIZE]u8 = undefined;
            const bytes_read = try log_file.pread(&header_bytes, file_pos);
            if (bytes_read < wal.WriteAheadLog.RecordHeader.SIZE) break;

            const header = try readLogHeader(&header_bytes);

            // Skip non-commit records
            if (header.record_type != @intFromEnum(wal.WriteAheadLog.RecordType.commit)) {
                file_pos += wal.WriteAheadLog.RecordHeader.SIZE + header.payload_len + wal.WriteAheadLog.RecordTrailer.SIZE;
                continue;
            }

            // Ensure we have enough bytes for full record
            const record_size = wal.WriteAheadLog.RecordHeader.SIZE + header.payload_len + wal.WriteAheadLog.RecordTrailer.SIZE;
            if (file_pos + record_size > file_size) break;

            // Read payload data
            const payload_data = try allocator.alloc(u8, header.payload_len);
            defer allocator.free(payload_data);

            const payload_read = try log_file.pread(payload_data, file_pos + wal.WriteAheadLog.RecordHeader.SIZE);
            if (payload_read < header.payload_len) break;

            // Deserialize commit record
            const commit_record = try wal.WriteAheadLog.deserializeCommitRecord(payload_data, allocator);
            defer cleanupCommitRecord(@constCast(&commit_record), allocator);

            // Extract tasks from this commit
            try cartridge.extractTasksFromCommit(commit_record);

            // Update source transaction ID
            cartridge.header.source_txn_id = commit_record.txn_id;

            file_pos += record_size;
        }

        return cartridge;
    }

    /// Extract tasks from a commit record and add to cartridge
    fn extractTasksFromCommit(self: *Self, commit: txn.CommitRecord) !void {
        for (commit.mutations) |mutation| {
            switch (mutation) {
                .put => |p| {
                    // Check if this is a task key (task:ID or task:ID:*)
                    if (std.mem.startsWith(u8, p.key, "task:")) {
                        // Check if task is not completed
                        if (extractTaskId(p.key)) |id| {
                            _ = id; // Task ID is implicitly used
                            // Check if task is completed by looking for completed:ID key
                            // (we can't check here since we only have mutations, not the full state)
                            // Add task to cartridge (will be filtered during finalization)
                            const task_type = try self.parseTaskType(p.value);
                            const priority = try self.parseTaskPriority(p.value);

                            const task = TaskEntry{
                                .key = try self.allocator.dupe(u8, p.key),
                                .task_type = try self.allocator.dupe(u8, task_type),
                                .priority = priority,
                                .claimed = false,
                                .claimed_by = null,
                                .claim_time = null,
                            };
                            try self.addTask(task);
                        }
                    }

                    // Track claim records
                    if (std.mem.startsWith(u8, p.key, "claim:")) {
                        // Parse claim:TASK_ID:AGENT_ID format
                        var parts = std.mem.splitSequence(u8, p.key, ":");
                        var part_idx: usize = 0;
                        var task_id_str: ?[]const u8 = null;
                        var agent_id_str: ?[]const u8 = null;

                        while (parts.next()) |part| {
                            if (part_idx == 1) task_id_str = part;
                            if (part_idx == 2) agent_id_str = part;
                            part_idx += 1;
                        }

                        if (task_id_str != null and agent_id_str != null) {
                            // Update task as claimed
                            const task_key = try std.fmt.allocPrint(self.allocator, "task:{s}", .{task_id_str.?});
                            const offset = self.key_index.get(task_key);
                            self.allocator.free(task_key);

                            if (offset) |off| {
                                _ = off; // Offset is implicitly used
                                // Mark task as claimed (we track this in a separate map)
                                // For now, we'll rebuild the final state in finalize()
                            }
                        }
                    }
                },
                .delete => |d| {
                    // If a claim is deleted, task is unclaimed or completed
                    if (std.mem.startsWith(u8, d.key, "claim:")) {
                        // Task was completed or released
                    }
                },
            }
        }
    }

    /// Parse task type from JSON metadata
    fn parseTaskType(self: *Self, value: []const u8) ![]const u8 {
        // Simple JSON parsing for type field
        // Format: {"priority":X,"type":Y,...}
        const type_key = "\"type\":";
        const type_start = std.mem.indexOf(u8, value, type_key) orelse {
            // Default type if not found
            return self.allocator.dupe(u8, "default");
        };

        var val_start = type_start + type_key.len;
        while (val_start < value.len and (value[val_start] == ' ' or value[val_start] == '\t')) {
            val_start += 1;
        }

        // Find end of type value
        var val_end = val_start;
        while (val_end < value.len and value[val_end] != ',' and value[val_end] != '}' and value[val_end] != ' ') {
            val_end += 1;
        }

        const type_str = value[val_start..val_end];
        return self.allocator.dupe(u8, type_str);
    }

    /// Parse task priority from JSON metadata
    fn parseTaskPriority(self: *Self, value: []const u8) !u8 {
        _ = self; // Self not used currently
        // Simple JSON parsing for priority field
        const priority_key = "\"priority\":";
        const priority_start = std.mem.indexOf(u8, value, priority_key) orelse return 128; // Default priority

        var val_start = priority_start + priority_key.len;
        while (val_start < value.len and (value[val_start] == ' ' or value[val_start] == '\t')) {
            val_start += 1;
        }

        // Find end of priority value
        var val_end = val_start;
        while (val_end < value.len and value[val_end] >= '0' and value[val_end] <= '9') {
            val_end += 1;
        }

        const priority_str = value[val_start..val_end];
        const priority = std.fmt.parseInt(u8, priority_str, 10) catch return 128;
        return priority;
    }

    /// Open an existing cartridge from file
    pub fn open(allocator: std.mem.Allocator, path: []const u8) !Self {
        const file = try std.fs.cwd().openFile(path, .{ .mode = .read_only });
        defer file.close();

        const file_size = try file.getEndPos();
        if (file_size < format.CartridgeHeader.SIZE) return error.FileTooSmall;

        // Read header
        var header_buf: [format.CartridgeHeader.SIZE]u8 = undefined;
        _ = try file.pread(&header_buf, 0);
        var fbs = std.io.fixedBufferStream(&header_buf);
        const header = try format.CartridgeHeader.deserialize(fbs.reader());
        try header.validate();

        if (header.cartridge_type != .pending_tasks_by_type) {
            return error.WrongCartridgeType;
        }

        // Read metadata
        const metadata_buf = try allocator.alloc(u8, file_size - header.metadata_offset);
        defer allocator.free(metadata_buf);
        _ = try file.pread(metadata_buf, header.metadata_offset);
        var metadata_fbs = std.io.fixedBufferStream(metadata_buf);
        const metadata = try format.CartridgeMetadata.deserialize(metadata_fbs.reader(), allocator);

        // Load index into memory
        var cartridge = Self{
            .allocator = allocator,
            .header = header,
            .metadata = metadata,
            .type_index = std.StringHashMap(TypeEntry).init(allocator),
            .key_index = std.StringHashMap(TaskOffset).init(allocator),
            .tasks = ArrayListManaged(TaskEntry).init(allocator),
            .mapped_data = null,
        };

        try cartridge.loadIndexFromFile(file);
        try cartridge.mapDataSection(file);
        return cartridge;
    }

    /// Load index from file
    fn loadIndexFromFile(self: *Self, file: std.fs.File) !void {
        // Read index section
        const index_size = self.header.data_offset - self.header.index_offset;
        const index_data = try self.allocator.alloc(u8, index_size);
        defer self.allocator.free(index_data);

        _ = try file.pread(index_data, self.header.index_offset);

        var fbs = std.io.fixedBufferStream(index_data);
        var reader = fbs.reader();

        // Read type count
        const type_count = try reader.readInt(u32, .little);

        // Read each type entry
        var i: u32 = 0;
        while (i < type_count) : (i += 1) {
            // Read type name length and string
            const type_name_len = try reader.readInt(u16, .little);
            const type_name = try self.allocator.alloc(u8, type_name_len);
            try reader.readNoEof(type_name);

            // Read task count
            _ = try reader.readInt(u32, .little); // task_count

            // Read first and last offsets
            const first_offset = try reader.readInt(u64, .little);
            const last_offset = try reader.readInt(u64, .little);

            // Skip checksum
            _ = try reader.readInt(u32, .little);

            // Create type entry - use a slice view instead of duplicating
            // The StringHashMap will own the type_name key
            const type_entry = TypeEntry{
                .task_type = type_name, // Reference the key from the map
                .tasks = ArrayListManaged(TaskOffset).init(self.allocator),
                .first_task_offset = first_offset,
                .last_task_offset = last_offset,
            };

            // For now, we don't load all task offsets (would be expensive)
            // In a real implementation, we'd lazily load tasks as needed

            try self.type_index.put(type_name, type_entry);
        }
    }

    /// Clean up cartridge resources
    pub fn deinit(self: *Self) void {
        // Clean up type index
        var type_it = self.type_index.iterator();
        while (type_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(self.allocator);
        }
        self.type_index.deinit();

        // Clean up key index
        var key_it = self.key_index.iterator();
        while (key_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.key_index.deinit();

        // Clean up tasks
        for (self.tasks.items) |*task| {
            task.deinit(self.allocator);
        }
        self.tasks.deinit();

        // Clean up metadata
        self.metadata.deinit(self.allocator);

        // Unmap file if mapped
        if (self.mapped_data) |data| {
            self.allocator.free(data);
        }
    }

    /// Add a task to the cartridge (during build phase)
    pub fn addTask(self: *Self, task: TaskEntry) !void {
        // Store full task for serialization
        const task_copy = TaskEntry{
            .key = try self.allocator.dupe(u8, task.key),
            .task_type = try self.allocator.dupe(u8, task.task_type),
            .priority = task.priority,
            .claimed = task.claimed,
            .claimed_by = if (task.claimed_by) |c| try self.allocator.dupe(u8, c) else null,
            .claim_time = task.claim_time,
        };
        try self.tasks.append(task_copy);

        // Add to key index (offset will be set during write)
        const key_copy = try self.allocator.dupe(u8, task.key);
        errdefer self.allocator.free(key_copy);
        const offset = TaskOffset{
            .offset = 0,
            .size = 0,
        };
        try self.key_index.put(key_copy, offset);

        // Add to type index
        const type_entry = try self.type_index.getOrPut(task.task_type);
        if (!type_entry.found_existing) {
            const type_copy = try self.allocator.dupe(u8, task.task_type);
            const task_offset_list = ArrayListManaged(TaskOffset).init(self.allocator);
            type_entry.value_ptr.* = TypeEntry{
                .task_type = type_copy,
                .tasks = task_offset_list,
                .first_task_offset = 0,
                .last_task_offset = 0,
            };
        }
        try type_entry.value_ptr.tasks.append(offset);

        self.header.entry_count += 1;
    }

    /// Get all tasks for a specific type
    pub fn getTasksByType(self: *const Self, task_type: []const u8) ![]CartridgeTaskEntry {
        const type_entry = self.type_index.get(task_type) orelse return &[_]CartridgeTaskEntry{};

        var tasks = ArrayListManaged(CartridgeTaskEntry).init(self.allocator);
        errdefer {
            for (tasks.items) |*t| t.deinit(self.allocator);
            tasks.deinit();
        }

        if (self.mapped_data) |data| {
            // Read from memory-mapped data
            for (type_entry.tasks.items) |offset| {
                const task = try self.readTaskAt(data, offset.offset);
                try tasks.append(task);
            }
        }

        return tasks.toOwnedSlice();
    }

    /// Get a specific task by key
    pub fn getTask(self: *const Self, key: []const u8) !?TaskEntry {
        const offset = self.key_index.get(key) orelse return null;

        if (self.mapped_data) |data| {
            return try self.readTaskAt(data, offset.offset);
        }

        return null;
    }

    /// Get task count for a specific type
    pub fn getTaskCount(self: *const Self, task_type: []const u8) usize {
        const type_entry = self.type_index.get(task_type) orelse return 0;
        return type_entry.tasks.items.len;
    }

    /// Check if cartridge needs rebuild based on invalidation policy
    pub fn needsRebuild(self: *const Self, current_txn_id: u64) bool {
        const txn_delta = current_txn_id - self.header.source_txn_id;
        return txn_delta >= self.metadata.invalidation_policy.max_new_txns;
    }

    /// Claim a task - returns updated task entry or error if not found/already claimed
    /// Note: This is a transient claim not persisted to the read-only cartridge.
    /// For persistent claims, write through to the main database and rebuild cartridge.
    pub fn claimTask(self: *const Self, key: []const u8, claimer: []const u8) !?TaskEntry {
        var task = (try self.getTask(key)) orelse return null;
        errdefer task.deinit(self.allocator);

        if (task.claimed) {
            task.deinit(self.allocator);
            return error.AlreadyClaimed;
        }

        // Return a claimed copy
        task.claimed = true;
        task.claimed_by = try self.allocator.dupe(u8, claimer);
        task.claim_time = @as(u64, @intCast(@divFloor(std.time.nanoTimestamp(), 1_000_000_000)));

        return task;
    }

    /// Read a task from data section
    fn readTaskAt(self: *const Self, data: []const u8, offset: u64) !TaskEntry {
        var pos: usize = @intCast(offset);
        if (pos + 8 > data.len) return error.InvalidTaskOffset;

        // Read task entry header: flags(1) + priority(1) + type_len(2) + key_len(4)
        const flags = data[pos];
        const priority = data[pos + 1];
        const type_len = std.mem.bytesToValue(u16, data[pos + 2 .. pos + 4]);
        const key_len = std.mem.bytesToValue(u32, data[pos + 4 .. pos + 8]);
        pos += 8;

        // Validate we have enough data
        const type_start = pos;
        const key_start = pos + @as(usize, type_len);
        const min_required = key_start + key_len;
        if (min_required > data.len) return error.InvalidTaskData;

        // Read type string
        const task_type = try self.allocator.dupe(u8, data[type_start..key_start]);
        errdefer self.allocator.free(task_type);

        // Read key string
        const key = try self.allocator.dupe(u8, data[key_start .. key_start + key_len]);
        errdefer self.allocator.free(key);
        pos = key_start + key_len;

        // Parse claim info if present (flags & 0x01 indicates claimed)
        var claimed = false;
        var claimed_by: ?[]const u8 = null;
        var claim_time: ?u64 = null;

        if (flags & 0x01 != 0 and pos + 12 <= data.len) {
            claimed = true;
            const claimant_len = std.mem.bytesToValue(u16, data[pos .. pos + 2]);
            pos += 2;
            if (claimant_len > 0 and pos + claimant_len + 8 <= data.len) {
                claimed_by = try self.allocator.dupe(u8, data[pos .. pos + claimant_len]);
                pos += claimant_len;
                claim_time = std.mem.bytesToValue(u64, data[pos .. pos + 8]);
            }
        }

        return TaskEntry{
            .key = key,
            .task_type = task_type,
            .priority = priority,
            .claimed = claimed,
            .claimed_by = claimed_by,
            .claim_time = claim_time,
        };
    }

    /// Write cartridge to file
    pub fn writeToFile(self: *Self, path: []const u8) !void {
        // Pre-calculate sizes to determine buffer size needed
        const header_size = format.CartridgeHeader.SIZE;
        const index_size = self.calculateIndexSize();
        const data_size = self.calculateDataSize();
        const metadata_size = self.metadata.serializedSize();
        const total_size = header_size + index_size + data_size + metadata_size;

        // Allocate buffer of exact needed size
        var buffer = try self.allocator.alloc(u8, total_size);
        defer self.allocator.free(buffer);

        var pos: usize = 0;

        // Write header (will be rewritten at the end)
        var header_fbs = std.io.fixedBufferStream(buffer[pos..]);
        try self.header.serialize(header_fbs.writer());
        pos += header_size;

        // Write index section
        self.header.index_offset = @intCast(pos);
        var index_fbs = std.io.fixedBufferStream(buffer[pos..pos + index_size]);
        try self.writeIndexSection(index_fbs.writer());
        pos += index_size;

        // Write data section
        self.header.data_offset = @intCast(pos);
        var data_fbs = std.io.fixedBufferStream(buffer[pos..pos + data_size]);
        try self.writeDataSection(data_fbs.writer());
        pos += data_size;

        // Write metadata section
        self.header.metadata_offset = @intCast(pos);
        var metadata_fbs = std.io.fixedBufferStream(buffer[pos..pos + metadata_size]);
        try self.metadata.serialize(metadata_fbs.writer());
        pos += metadata_size;

        // Calculate and write checksum using CRC32C
        self.header.checksum = pager.crc32c(buffer[0..pos]);

        // Rewrite header with final offsets and checksum
        var final_header_fbs = std.io.fixedBufferStream(buffer[0..header_size]);
        try self.header.serialize(final_header_fbs.writer());

        // Write to file
        const file = try std.fs.cwd().createFile(path, .{ .read = true });
        defer file.close();
        try file.writeAll(buffer[0..pos]);
    }

    fn calculateIndexSize(self: *const Self) usize {
        var size: usize = 4; // type count
        var it = self.type_index.iterator();
        while (it.next()) |entry| {
            const type_entry = entry.value_ptr.*;
            size += 2 + type_entry.task_type.len; // type name length + name
            size += 4 + 8 + 8 + 4; // task count + offsets + checksum
        }
        return size;
    }

    fn writeIndexSection(self: *Self, writer: anytype) !void {
        try writer.writeInt(u32, @intCast(self.type_index.count()), .little);

        var task_idx: usize = 0;
        var it = self.type_index.iterator();
        while (it.next()) |entry| {
            const type_entry = entry.value_ptr.*;
            try writer.writeInt(u16, @intCast(type_entry.task_type.len), .little);
            try writer.writeAll(type_entry.task_type);
            try writer.writeInt(u32, @intCast(type_entry.tasks.items.len), .little);
            try writer.writeInt(u64, 0, .little); // first_task_offset placeholder
            try writer.writeInt(u64, 0, .little); // last_task_offset placeholder
            try writer.writeInt(u32, 0, .little); // checksum placeholder

            // Update offset tracking for this type
            for (type_entry.tasks.items) |*off| {
                off.*.offset = 0; // Will be set when writing data
                off.*.size = 0;

                // Track which task we're on
                _ = task_idx < self.tasks.items.len;
                task_idx += 1;
            }
        }
    }

    /// Map data section into memory for fast access
    fn mapDataSection(self: *Self, file: std.fs.File) !void {
        const data_size = self.header.metadata_offset - self.header.data_offset;
        if (data_size == 0) {
            self.mapped_data = null;
            return;
        }

        const data = try self.allocator.alloc(u8, data_size);
        errdefer self.allocator.free(data);
        const bytes_read = try file.pread(data, self.header.data_offset);
        if (bytes_read != data_size) return error.IOError;

        // Parse data section to build key_index and update type task offsets
        var offset: u64 = 0;
        var type_task_counts = std.StringHashMap(usize).init(self.allocator);
        defer type_task_counts.deinit();

        // First pass: parse all tasks and build key_index
        while (offset < @as(u64, @intCast(data_size))) {
            if (offset + 8 > data_size) break;

            const start_offset = offset;
            const flags = data[@intCast(offset)];
            _ = data[@intCast(offset + 1)]; // priority
            const type_len = std.mem.bytesToValue(u16, data[@intCast(offset + 2) .. @intCast(offset + 4)]);
            const key_len = std.mem.bytesToValue(u32, data[@intCast(offset + 4) .. @intCast(offset + 8)]);
            offset += 8;

            // Read type and key
            if (offset + type_len + key_len > data_size) break;
            const type_str = data[@intCast(offset) .. @intCast(offset + type_len)];
            offset += type_len;
            const key_str = data[@intCast(offset) .. @intCast(offset + key_len)];
            offset += key_len;

            // Read claim info if present
            if (flags & 0x01 != 0 and offset + 10 <= data_size) {
                const claimant_len = std.mem.bytesToValue(u16, data[@intCast(offset) .. @intCast(offset + 2)]);
                offset += 2 + claimant_len + 8;
            }

            const entry_size = offset - start_offset;

            // Add to key_index
            const key_copy = try self.allocator.dupe(u8, key_str);
            try self.key_index.put(key_copy, TaskOffset{
                .offset = start_offset,
                .size = entry_size,
            });

            // Track task count per type
            const count_entry = try type_task_counts.getOrPut(type_str);
            if (!count_entry.found_existing) {
                const type_copy = try self.allocator.dupe(u8, type_str);
                _ = try type_task_counts.put(type_copy, 0);
            }
            count_entry.value_ptr.* += 1;
        }

        // Second pass: update type_index task offsets
        var task_idx: usize = 0;
        offset = 0;
        while (offset < @as(u64, @intCast(data_size))) {
            if (offset + 8 > data_size) break;

            const start_offset = offset;
            const flags = data[@intCast(offset)];
            _ = data[@intCast(offset + 1)]; // priority
            const type_len = std.mem.bytesToValue(u16, data[@intCast(offset + 2) .. @intCast(offset + 4)]);
            const key_len = std.mem.bytesToValue(u32, data[@intCast(offset + 4) .. @intCast(offset + 8)]);
            offset += 8;

            if (offset + type_len + key_len > data_size) break;
            const type_str = data[@intCast(offset) .. @intCast(offset + type_len)];
            offset += type_len;
            offset += key_len; // skip key

            if (flags & 0x01 != 0 and offset + 10 <= data_size) {
                const claimant_len = std.mem.bytesToValue(u16, data[@intCast(offset) .. @intCast(offset + 2)]);
                offset += 2 + claimant_len + 8;
            }

            // Update type entry
            if (self.type_index.getPtr(type_str)) |entry| {
                if (entry.tasks.items.len == 0) {
                    entry.first_task_offset = start_offset;
                }
                entry.last_task_offset = start_offset;
                const task_off = TaskOffset{
                    .offset = start_offset,
                    .size = offset - start_offset,
                };
                try entry.tasks.append(task_off);
            }
            task_idx += 1;
        }

        self.mapped_data = data;
    }

    fn calculateDataSize(self: *const Self) usize {
        var size: usize = 0;
        for (self.tasks.items) |task| {
            size += 1 + 1 + 2 + task.task_type.len + 4 + task.key.len; // flags + priority + type_len + type + key_len + key
            if (task.claimed) {
                size += 2 + (task.claimed_by orelse "").len + 8; // claimant_len + claimant + claim_time
            }
        }
        return size;
    }

    fn writeDataSection(self: *const Self, writer: anytype) !void {
        // Write all tasks to data section
        // Each task entry: flags(1) + priority(1) + type_len(2) + type + key_len(4) + key [+ claim_info]
        for (self.tasks.items) |task| {
            var flags: u8 = 0;
            if (task.claimed) flags |= 0x01;

            try writer.writeByte(flags);
            try writer.writeByte(task.priority);
            try writer.writeInt(u16, @intCast(task.task_type.len), .little);
            try writer.writeAll(task.task_type);
            try writer.writeInt(u32, @intCast(task.key.len), .little);
            try writer.writeAll(task.key);

            // Write claim info if claimed
            if (task.claimed) {
                const claimant = task.claimed_by orelse "";
                try writer.writeInt(u16, @intCast(claimant.len), .little);
                try writer.writeAll(claimant);
                try writer.writeInt(u64, task.claim_time orelse 0, .little);
            }
        }
    }
};

/// Create default invalidation policy for task cartridges
fn createTaskInvalidationPolicy(allocator: std.mem.Allocator) !format.InvalidationPolicy {
    var policy = format.InvalidationPolicy.init(allocator);
    policy.max_age_seconds = 3600; // 1 hour
    policy.min_new_txns = 10;
    policy.max_new_txns = 1000;

    // Task operations trigger invalidation
    const task_prefix = try allocator.dupe(u8, "task:");
    try policy.addPattern(allocator, .{
        .key_prefix = task_prefix,
        .check_mutation_type = true,
        .mutation_type = .put,
    });

    const delete_prefix = try allocator.dupe(u8, "task:");
    try policy.addPattern(allocator, .{
        .key_prefix = delete_prefix,
        .check_mutation_type = true,
        .mutation_type = .delete,
    });

    return policy;
}

/// Extract task ID from a key (e.g., "task:42" -> 42)
fn extractTaskId(key: []const u8) ?u64 {
    if (!std.mem.startsWith(u8, key, "task:")) return null;

    // Find the end of the task ID (colon or end)
    var id_end = key.len;
    if (std.mem.indexOfScalarPos(u8, key, 5, ':')) |pos| {
        id_end = pos;
    }

    const id_str = key[5..id_end];
    return std.fmt.parseInt(u64, id_str, 10) catch null;
}

/// Read log header from byte buffer
fn readLogHeader(bytes: []const u8) !wal.WriteAheadLog.RecordHeader {
    if (bytes.len < wal.WriteAheadLog.RecordHeader.SIZE) return error.InvalidHeaderSize;

    return wal.WriteAheadLog.RecordHeader{
        .magic = std.mem.bytesToValue(u32, bytes[0..4]),
        .record_version = std.mem.bytesToValue(u16, bytes[4..6]),
        .record_type = std.mem.bytesToValue(u16, bytes[6..8]),
        .header_len = std.mem.bytesToValue(u16, bytes[8..10]),
        .flags = std.mem.bytesToValue(u16, bytes[10..12]),
        .txn_id = std.mem.bytesToValue(u64, bytes[12..20]),
        .prev_lsn = std.mem.bytesToValue(u64, bytes[20..28]),
        .payload_len = std.mem.bytesToValue(u32, bytes[28..32]),
        .header_crc32c = std.mem.bytesToValue(u32, bytes[32..36]),
        .payload_crc32c = std.mem.bytesToValue(u32, bytes[36..40]),
    };
}

/// Clean up a commit record and all its allocated data
fn cleanupCommitRecord(record: *txn.CommitRecord, allocator: std.mem.Allocator) void {
    for (record.mutations) |mutation| {
        switch (mutation) {
            .put => |p| {
                allocator.free(p.key);
                allocator.free(p.value);
            },
            .delete => |d| {
                allocator.free(d.key);
            },
        }
    }
    allocator.free(record.mutations);
}

// ==================== Tests ====================

test "PendingTasksCartridge.init" {
    var cartridge = try PendingTasksCartridge.init(std.testing.allocator, 100);
    defer cartridge.deinit();

    try std.testing.expectEqual(format.CartridgeType.pending_tasks_by_type, cartridge.header.cartridge_type);
    try std.testing.expectEqual(@as(u64, 100), cartridge.header.source_txn_id);
    try std.testing.expectEqual(@as(u64, 0), cartridge.header.entry_count);
}

test "PendingTasksCartridge.addTask and getTaskCount" {
    var cartridge = try PendingTasksCartridge.init(std.testing.allocator, 100);
    defer cartridge.deinit();

    try std.testing.expectEqual(@as(usize, 0), cartridge.getTaskCount("processing"));

    const task = TaskEntry{
        .key = "task:001",
        .task_type = "processing",
        .priority = 10,
        .claimed = false,
        .claimed_by = null,
        .claim_time = null,
    };
    try cartridge.addTask(task);

    try std.testing.expectEqual(@as(u64, 1), cartridge.header.entry_count);
    try std.testing.expectEqual(@as(usize, 1), cartridge.getTaskCount("processing"));
}

test "PendingTasksCartridge.needsRebuild" {
    var cartridge = try PendingTasksCartridge.init(std.testing.allocator, 100);
    defer cartridge.deinit();

    // Default max_new_txns is 1000
    const policy = &cartridge.metadata.invalidation_policy;

    // Within limit: no rebuild needed
    try std.testing.expect(!cartridge.needsRebuild(150));

    // At limit: rebuild needed
    try std.testing.expect(cartridge.needsRebuild(1100));

    // Change policy to test custom limit
    policy.max_new_txns = 50;
    try std.testing.expect(cartridge.needsRebuild(160));
}

test "PendingTasksCartridge.buildFromLog" {
    const test_log = "test_build_cartridge.log";
    defer {
        _ = std.fs.cwd().deleteFile(test_log) catch {};
    }

    // Create a log file with task-related mutations
    {
        var temp_wal = try wal.WriteAheadLog.create(test_log, std.testing.allocator);
        defer temp_wal.deinit();

        // Create commit records with task operations
        const mutations1 = [_]txn.Mutation{
            txn.Mutation{ .put = .{ .key = "task:1", .value = "{\"priority\":5,\"type\":\"processing\"}" } },
            txn.Mutation{ .put = .{ .key = "task:2", .value = "{\"priority\":10,\"type\":\"upload\"}" } },
        };

        var record1 = txn.CommitRecord{
            .txn_id = 1,
            .root_page_id = 2,
            .mutations = &mutations1,
            .checksum = 0,
        };
        record1.checksum = record1.calculatePayloadChecksum();
        _ = try temp_wal.appendCommitRecord(record1);
        try temp_wal.flush();
    }

    // Build cartridge from log
    var cartridge = try PendingTasksCartridge.buildFromLog(std.testing.allocator, test_log);
    defer cartridge.deinit();

    // Verify tasks were extracted
    try std.testing.expectEqual(@as(u64, 1), cartridge.header.source_txn_id);
    try std.testing.expect(cartridge.header.entry_count > 0);
}

test "PendingTasksCartridge.writeToFile" {
    var cartridge = try PendingTasksCartridge.init(std.testing.allocator, 100);
    defer cartridge.deinit();

    const task = TaskEntry{
        .key = "task:001",
        .task_type = "processing",
        .priority = 10,
        .claimed = false,
        .claimed_by = null,
        .claim_time = null,
    };
    try cartridge.addTask(task);

    const test_path = "test_pending_tasks.cartridge";
    defer {
        _ = std.fs.cwd().deleteFile(test_path) catch {};
    }

    try cartridge.writeToFile(test_path);

    // Verify file was created
    const file = try std.fs.cwd().openFile(test_path, .{ .mode = .read_only });
    defer file.close();
    const file_size = try file.getEndPos();
    try std.testing.expect(file_size > 0);
}

test "PendingTasksCartridge.open" {
    const test_path = "test_pending_tasks_open.cartridge";
    defer {
        _ = std.fs.cwd().deleteFile(test_path) catch {};
    }

    // Create and write cartridge
    {
        var cartridge = try PendingTasksCartridge.init(std.testing.allocator, 100);
        defer cartridge.deinit();

        const task = TaskEntry{
            .key = "task:001",
            .task_type = "processing",
            .priority = 10,
            .claimed = false,
            .claimed_by = null,
            .claim_time = null,
        };
        try cartridge.addTask(task);
        try cartridge.writeToFile(test_path);
    }

    // Open existing cartridge
    var cartridge = try PendingTasksCartridge.open(std.testing.allocator, test_path);
    defer cartridge.deinit();

    try std.testing.expectEqual(format.CartridgeType.pending_tasks_by_type, cartridge.header.cartridge_type);
    try std.testing.expectEqual(@as(u64, 100), cartridge.header.source_txn_id);
}

test "extractTaskId" {
    try std.testing.expectEqual(@as(u64, 42), extractTaskId("task:42").?);
    try std.testing.expectEqual(@as(u64, 123), extractTaskId("task:123:extra").?);
    try std.testing.expect(extractTaskId("notatask") == null);
    try std.testing.expect(extractTaskId("task:") == null);
    try std.testing.expect(extractTaskId("task:abc") == null);
}

test "PendingTasksCartridge.deterministic_rebuild" {
    const test_log = "test_deterministic_rebuild.log";
    defer {
        _ = std.fs.cwd().deleteFile(test_log) catch {};
    }

    // Create a log file with deterministic commit records
    {
        var temp_wal = try wal.WriteAheadLog.create(test_log, std.testing.allocator);
        defer temp_wal.deinit();

        // Create three commit records
        const mutations1 = [_]txn.Mutation{
            txn.Mutation{ .put = .{ .key = "task:1", .value = "{\"priority\":5,\"type\":\"processing\"}" } },
            txn.Mutation{ .put = .{ .key = "task:2", .value = "{\"priority\":10,\"type\":\"upload\"}" } },
        };

        var record1 = txn.CommitRecord{
            .txn_id = 1,
            .root_page_id = 2,
            .mutations = &mutations1,
            .checksum = 0,
        };
        record1.checksum = record1.calculatePayloadChecksum();
        _ = try temp_wal.appendCommitRecord(record1);

        const mutations2 = [_]txn.Mutation{
            txn.Mutation{ .put = .{ .key = "task:3", .value = "{\"priority\":3,\"type\":\"processing\"}" } },
        };

        var record2 = txn.CommitRecord{
            .txn_id = 2,
            .root_page_id = 3,
            .mutations = &mutations2,
            .checksum = 0,
        };
        record2.checksum = record2.calculatePayloadChecksum();
        _ = try temp_wal.appendCommitRecord(record2);

        try temp_wal.flush();
    }

    // Build cartridge twice from same log
    var cartridge1 = try PendingTasksCartridge.buildFromLog(std.testing.allocator, test_log);
    defer cartridge1.deinit();

    var cartridge2 = try PendingTasksCartridge.buildFromLog(std.testing.allocator, test_log);
    defer cartridge2.deinit();

    // Verify deterministic properties match
    try std.testing.expectEqual(cartridge1.header.source_txn_id, cartridge2.header.source_txn_id);
    try std.testing.expectEqual(cartridge1.header.entry_count, cartridge2.header.entry_count);
    try std.testing.expectEqual(cartridge1.type_index.count(), cartridge2.type_index.count());

    // Verify both cartridges have the same task types
    var it = cartridge1.type_index.iterator();
    while (it.next()) |entry| {
        const type_name = entry.key_ptr.*;
        const count1 = entry.value_ptr.tasks.items.len;
        const count2 = cartridge2.getTaskCount(type_name);
        try std.testing.expectEqual(count1, count2);
    }
}

test "PendingTasksCartridge.parseTaskType" {
    var cartridge = try PendingTasksCartridge.init(std.testing.allocator, 0);
    defer cartridge.deinit();

    const json_with_type = "{\"priority\":5,\"type\":\"processing\",\"created_at\":12345}";
    const parsed_type = try cartridge.parseTaskType(json_with_type);
    defer std.testing.allocator.free(parsed_type);
    try std.testing.expectEqualStrings("processing", parsed_type);

    // Test with missing type field (should return "default")
    const json_without_type = "{\"priority\":5,\"created_at\":12345}";
    const default_type = try cartridge.parseTaskType(json_without_type);
    defer std.testing.allocator.free(default_type);
    try std.testing.expectEqualStrings("default", default_type);
}

test "PendingTasksCartridge.parseTaskPriority" {
    var cartridge = try PendingTasksCartridge.init(std.testing.allocator, 0);
    defer cartridge.deinit();

    const json_with_priority = "{\"priority\":42,\"type\":\"processing\"}";
    const priority = try cartridge.parseTaskPriority(json_with_priority);
    try std.testing.expectEqual(@as(u8, 42), priority);

    // Test with missing priority field (should return 128 default)
    const json_without_priority = "{\"type\":\"processing\"}";
    const default_priority = try cartridge.parseTaskPriority(json_without_priority);
    try std.testing.expectEqual(@as(u8, 128), default_priority);
}

test "PendingTasksCartridge.memory_map_lookups" {
    const test_path = "test_memory_map.cartridge";
    defer {
        _ = std.fs.cwd().deleteFile(test_path) catch {};
    }

    // Create and write cartridge with multiple tasks
    {
        var cartridge = try PendingTasksCartridge.init(std.testing.allocator, 100);
        defer cartridge.deinit();

        // Add tasks of different types
        const task1 = TaskEntry{
            .key = "task:001",
            .task_type = "processing",
            .priority = 10,
            .claimed = false,
            .claimed_by = null,
            .claim_time = null,
        };
        try cartridge.addTask(task1);

        const task2 = TaskEntry{
            .key = "task:002",
            .task_type = "upload",
            .priority = 5,
            .claimed = false,
            .claimed_by = null,
            .claim_time = null,
        };
        try cartridge.addTask(task2);

        const task3 = TaskEntry{
            .key = "task:003",
            .task_type = "processing",
            .priority = 15,
            .claimed = false,
            .claimed_by = null,
            .claim_time = null,
        };
        try cartridge.addTask(task3);

        try cartridge.writeToFile(test_path);
    }

    // Open and test memory-mapped lookups
    var cartridge = try PendingTasksCartridge.open(std.testing.allocator, test_path);
    defer cartridge.deinit();

    // Verify data is mapped
    try std.testing.expect(cartridge.mapped_data != null);

    // Test getTask by key
    const task = try cartridge.getTask("task:001");
    try std.testing.expect(task != null);
    defer if (task) |t| {
        var t_mut = t;
        t_mut.deinit(std.testing.allocator);
    };
    try std.testing.expectEqualStrings("task:001", task.?.key);
    try std.testing.expectEqualStrings("processing", task.?.task_type);
    try std.testing.expectEqual(@as(u8, 10), task.?.priority);

    // Test getTasksByType
    const processing_tasks = try cartridge.getTasksByType("processing");
    defer {
        for (processing_tasks) |*t| t.deinit(std.testing.allocator);
        std.testing.allocator.free(processing_tasks);
    }
    try std.testing.expectEqual(@as(usize, 2), processing_tasks.len);

    const upload_tasks = try cartridge.getTasksByType("upload");
    defer {
        for (upload_tasks) |*t| t.deinit(std.testing.allocator);
        std.testing.allocator.free(upload_tasks);
    }
    try std.testing.expectEqual(@as(usize, 1), upload_tasks.len);

    // Test claimTask
    var claimed = try cartridge.claimTask("task:002", "agent-42");
    try std.testing.expect(claimed != null);
    defer if (claimed) |*c| c.deinit(std.testing.allocator);
    try std.testing.expect(claimed.?.claimed);
    try std.testing.expectEqualStrings("agent-42", claimed.?.claimed_by.?);
}

test "PendingTasksCartridge.claimTask_errors" {
    const test_path = "test_claim_errors.cartridge";
    defer {
        _ = std.fs.cwd().deleteFile(test_path) catch {};
    }

    // Create cartridge with a claimed task
    {
        var cartridge = try PendingTasksCartridge.init(std.testing.allocator, 100);
        defer cartridge.deinit();

        const task = TaskEntry{
            .key = "task:001",
            .task_type = "processing",
            .priority = 10,
            .claimed = true,
            .claimed_by = "agent-1",
            .claim_time = 12345,
        };
        try cartridge.addTask(task);
        try cartridge.writeToFile(test_path);
    }

    var cartridge = try PendingTasksCartridge.open(std.testing.allocator, test_path);
    defer cartridge.deinit();

    // Try to claim already claimed task
    const result = cartridge.claimTask("task:001", "agent-2");
    try std.testing.expectError(error.AlreadyClaimed, result);

    // Try to claim non-existent task
    const not_found = try cartridge.claimTask("task:999", "agent-2");
    try std.testing.expect(not_found == null);
}
