pub fn main() !void {
    var debug_allocator = std.heap.DebugAllocator(.{}).init;
    const allocator = debug_allocator.allocator();
    defer _ = debug_allocator.deinit();
    var initial_counts = std.AutoHashMap(
        struct { u32, u32 },
        u32,
    ).init(allocator);
    defer initial_counts.deinit();

    try initial_counts.put(.{ 1, 2 }, 5);
    try initial_counts.put(.{ 2, 3 }, 10);

    const ids = [_]u32{ 1, 2, 3 };
    var counts = try lib.getStats(allocator, ids[0..], initial_counts);
    defer counts.deinit(); // <- Seg-faults here!

    std.debug.print(
        "{}, {}",
        .{ counts.get(.{ 1, 2 }).? == 6, counts.get(.{ 2, 3 }).? == 11 },
    );
}

const std = @import("std");
const lib = @import("zbpe_lib");
