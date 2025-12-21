const std = @import("std");
pub fn main() !void {
    const allocator = std.heap.page_allocator;
    var list = std.ArrayList(u64).initCapacity(allocator, 10) catch unreachable;
    defer list.deinit();
    try list.append(42);
    std.debug.print("ArrayList works: {}\n", .{list.items[0]});
}
