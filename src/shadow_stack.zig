const object = @import("object.zig");
const Object = object.Object;

pub const Frame = struct {
    const Self = @This();

    next: ?*Self = null,
    pointers: []?*Object,
    offset: usize = 0,

    pub fn push(self: *Self, root: *Object) void {
        self.pointers[self.offset] = root;
        self.offset += 1;
    }

    // fn init(pointers: []*Object) Self {
    //     return Self{
    //         .next = null,
    //         .pointers = pointers,
    //     };
    // }
};

pub const Stack = struct {
    const Self = @This();

    node: ?*Frame = null,

    pub fn push(self: *Self, node: *Frame) void {
        node.next = self.node;
        self.node = node;
    }

    pub fn pop(self: *Self) void {
        self.node = self.node.?.next;
    }
};
