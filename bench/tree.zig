const std = @import("std");

const zbench = @import("zbench");
const zig_gc = @import("zig_gc");

fn run(allocator: std.mem.Allocator) !void {
    var vec = std.ArrayList(usize).init(allocator);
    const n: usize = 1000;
    for (0..n) |i| {
        try vec.append(n - i);
    }
    for (0..1000) |i| {
        _ = i;
        std.sort.pdq(usize, vec.items, {}, std.sort.asc(usize));
    }
}

fn bench(allocator: std.mem.Allocator) void {
    if (run(allocator)) |_| {} else |err| {
        std.debug.panic("Failed to run benchmark {}", .{err});
    }
}

pub fn main() !void {
    var b = zbench.Benchmark.init(std.heap.c_allocator, .{});
    defer b.deinit();
    try b.add("My Benchmark", bench, .{});
    try b.run(std.io.getStdOut().writer());
}
