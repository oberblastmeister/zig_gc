const object = @import("object.zig");
const Object = object.Object;

pub const Node = struct {
    const Self = @This();

    prev: ?*Self,
    pointers: []?*Object,

    fn init(pointers: []*Object) Self {
        return Self{
            .prev = null,
            .pointers = pointers,
        };
    }
};

pub const Stack = struct {
    const Self = @This();
    node: ?*Node,

    pub fn push(self: *Self, node: *Node) void {
        node.prev = self.node;
        self.node = node;
    }

    pub fn pop(self: *Self) void {
        self.node = self.node.?.prev;
    }
};
