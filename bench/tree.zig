const std = @import("std");

const zbench = @import("zbench");
const zgc = @import("zig_gc");
const types = zgc.types;
const Object = zgc.Object;
const shadow_stack = zgc.shadow_stack;

fn createLeafNode(gc: anytype, value_: Object) Object {
    var roots = [_]?*Object{null} ** 10;
    var frame = shadow_stack.Frame{ .pointers = &roots };
    gc.stack.push(&frame);
    defer gc.stack.pop();

    var value = value_;
    frame.push(&value);

    var left = types.toObject(types.createRecord(gc, types.BinaryTree.Empty, .{}));
    frame.push(&left);

    var right = types.toObject(types.createRecord(gc, types.BinaryTree.Empty, .{}));
    frame.push(&right);

    var result = types.toObject(types.createRecord(gc, types.BinaryTree.Node, .{ .left = left, .right = right, .value = value }));
    frame.push(&result);

    return result;
}

fn makeTree(gc: anytype, depth: usize) Object {
    var roots = [_]?*Object{null} ** 10;
    var frame = shadow_stack.Frame{ .pointers = &roots };
    gc.stack.push(&frame);
    defer gc.stack.pop();

    if (depth <= 0) {
        var result = types.toObject(types.createRecord(gc, types.BinaryTree.Empty, .{}));
        frame.push(&result);

        return result;
    } else {
        var left = makeTree(gc, depth - 1);
        frame.push(&left);

        var right = makeTree(gc, depth - 1);
        frame.push(&right);

        var value = types.toObject(types.createRecord(gc, types.Int, .{ .value = depth }));
        frame.push(&value);

        var result = types.toObject(types.createRecord(gc, types.BinaryTree.Node, .{ .left = left, .right = right, .value = value }));
        frame.push(&result);

        return result;
    }
}

fn populateTreeMut(gc: anytype, tree_: *types.BinaryTree.Node, depth: usize) void {
    var roots = [_]?*Object{null} ** 10;
    var frame = shadow_stack.Frame{ .pointers = &roots };
    gc.stack.push(&frame);
    defer gc.stack.pop();

    const tree = tree_;
    var tree_obj = types.toObject(tree_);
    frame.push(&tree_obj);

    if (depth <= 0) {
        return;
    } else {
        var depth_obj = types.toObject(types.createRecord(gc, types.Int, .{ .value = depth }));
        frame.push(&depth_obj);

        var left = createLeafNode(gc, depth_obj);
        frame.push(&left);

        var right = createLeafNode(gc, depth_obj);
        frame.push(&right);

        types.write(gc, tree, "left", left);
        types.write(gc, tree, "right", right);

        populateTreeMut(gc, @ptrCast(types.read(gc, tree, "left")), depth - 1);
        populateTreeMut(gc, @ptrCast(types.read(gc, tree, "right")), depth - 1);

        return;
    }
}

// about 16Mb
const stretch_tree_depth: usize = 18; // about 16Mb
const long_lived_array_size: usize = 500000;

fn treeBench(gc: anytype) void {
    var roots = [_]?*Object{null} ** 10;
    var frame = shadow_stack.Frame{ .pointers = &roots };
    gc.stack.push(&frame);
    defer gc.stack.pop();

    _ = makeTree(gc, stretch_tree_depth);

    var obj = types.toObject(types.createRecord(gc, types.Int, .{ .value = 0 }));
    frame.push(&obj);

    var long_lived_tree = createLeafNode(gc, obj);
    frame.push(&long_lived_tree);

    populateTreeMut(gc, @ptrCast(long_lived_tree), stretch_tree_depth - 2);

    var long_lived_array = types.Array.create(gc, long_lived_array_size);
    var array_obj = types.toObject(long_lived_array);
    frame.push(&array_obj);

    for (0..long_lived_array_size) |i| {
        const value = types.toObject(types.createRecord(gc, types.Int, .{ .value = i }));
        long_lived_array.items()[i] = value;
    }

    for (0..long_lived_array_size) |i| {
        if (i % 7 == 0) {
            long_lived_array.items()[i] = null;
        }
    }
}

fn run_semispace(allocator: std.mem.Allocator) !void {
    _ = allocator;

    var semispace = try zgc.Semispace.init();
    defer semispace.deinit();
    defer semispace.collect();

    treeBench(&semispace);

    // std.debug.print("Collected {} times\n", .{semispace.stats.collections});
}

fn run_mark_compact(allocator: std.mem.Allocator) !void {
    _ = allocator;

    var lisp2 = try zgc.Lisp2Hash.init(std.heap.c_allocator);
    defer lisp2.deinit();
    defer lisp2.collect();

    treeBench(&lisp2);

    // std.debug.print("Collected {} times\n", .{lisp2.stats.collections});
}

fn bench_semispace(allocator: std.mem.Allocator) void {
    if (run_semispace(allocator)) |_| {} else |err| {
        std.debug.panic("Failed to run benchmark {}", .{err});
    }
}

fn bench_mark_compact(allocator: std.mem.Allocator) void {
    if (run_mark_compact(allocator)) |_| {} else |err| {
        std.debug.panic("Failed to run benchmark {}", .{err});
    }
}

pub fn main() !void {
    var b = zbench.Benchmark.init(std.heap.c_allocator, .{});
    defer b.deinit();
    try b.add("Semispace", bench_semispace, .{});
    try b.add("Mark-Compact", bench_mark_compact, .{});
    try b.run(std.io.getStdOut().writer());
}
