const std = @import("std");

const GcConfig = @import("GcConfig.zig");
const object = @import("object.zig");
const Header = object.Header;
const InfoTable = object.InfoTable;
const RecordInfoTable = object.InfoTable;
const semispace = @import("semispace.zig");
const types = @import("types.zig");
const types_constructors = @import("types_constructors.zig");
const shadow_stack = @import("shadow_stack.zig");

const GC = semispace.MakeGC(types);

const P = semispace.MakeP(GC).P;

const C = types_constructors.Make(GC);

test "first" {
    var gc = try GC.init();

    var stack = [_]?*object.Object{null} ** 100;
    var frame = shadow_stack.Node{ .prev = null, .pointers = &stack };
    gc.stack.push(&frame);
    defer gc.stack.pop();

    var n1 = C.Int.create(&gc, 10);
    stack[0] = @ptrCast(&n1);

    var n2 = C.Int.create(&gc, 1234);
    stack[1] = @ptrCast(&n2);

    var p1 = C.Pair.create(&gc, @ptrCast(n1), @ptrCast(n2));
    stack[2] = @ptrCast(&p1);

    var a1 = C.Array.create(&gc, 100);
    stack[3] = @ptrCast(&a1);

    var b1 = C.Bytes.create(&gc, 13);
    b1.items()[1] = 123;

    for (0..10) |i| {
        const int = C.Int.create(&gc, i);
        a1.items()[i] = @ptrCast(int);
    }

    gc.collect();
}
