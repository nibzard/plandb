const std = @import("std");
pub fn main() !void {
    const allocator = std.heap.page_allocator;
    var list = std.ArrayList(u64).initCapacity(allocator, 10) catch unreachable;
    defer list.deinit(allocator);
    try list.append(allocator, 42);
    try list.append(allocator, 84);
    list.clearAndRetainCapacity();
    try list.append(allocator, 123);
    std.debug.print("ArrayList capacity: {}, len: {}, item: {}\n", .{list.capacity, list.items.len, list.items[0]});
}
