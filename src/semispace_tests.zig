const std = @import("std");

const GcConfig = @import("GcConfig.zig");
const object = @import("object.zig");
const Header = object.Header;
const Object = object.Object;
const InfoTable = object.InfoTable;
const RecordInfoTable = object.InfoTable;
const semispace = @import("semispace.zig");
const shadow_stack = @import("shadow_stack.zig");
const Stack = shadow_stack.Stack;
const types = @import("types.zig");
const types_constructors = @import("types_constructors.zig");

const GC = semispace.MakeGC(.{
    .processFields = types.processFields,
    .objectSize = types.objectSize,
});

const P = semispace.MakeP(GC).P;

const C = types_constructors.Make(GC);

test "first" {
    var gc = try GC.init();

    // var stack = P(100).init(.{null} ** 100);
    var roots = [_]?*Object{null} ** 100;
    var frame = .{ .pointers = &roots };
    gc.stack.push(&frame);
    defer gc.stack.pop();

    var n1 = C.Int.create(&gc, 10);
    roots[0] = @ptrCast(&n1);

    var n2 = C.Int.create(&gc, 1234);
    roots[1] = @ptrCast(&n2);

    var p1 = C.Pair.create(&gc, @ptrCast(n1), @ptrCast(n2));
    roots[2] = @ptrCast(&p1);

    var a1 = C.Array.create(&gc, 100);
    roots[3] = @ptrCast(&a1);

    for (0..10) |i| {
        const int = C.Int.create(&gc, i);
        a1.items()[i] = @ptrCast(int);
    }

    gc.collect();
}
