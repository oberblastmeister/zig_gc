//! By convention, root.zig is the root source file when making a library. If
//! you are making an executable, the convention is to delete this file and
//! start with main.zig instead.
const std = @import("std");
const testing = std.testing;

pub const MarkCompactHash = @import("mark_compact_hash.zig");
pub const Semispace = @import("semispace.zig");
pub const types = @import("types.zig");
pub const object = @import("object.zig");
pub const Object = object.Object;
pub const Header = object.Header;
pub const shadow_stack = @import("shadow_stack.zig");

comptime {
    @setEvalBranchQuota(5000);

    _ = testing.refAllDeclsRecursive(@import("mark_compact_hash_tests.zig"));
    _ = testing.refAllDeclsRecursive(@import("semispace_tests.zig"));

    // _ = testing.refAllDeclsRecursive(@import("mark_compact_hash.zig"));
    // _ = testing.refAllDeclsRecursive(@import("object.zig"));
    // _ = testing.refAllDeclsRecursive(@import("types.zig"));
    // _ = testing.refAllDeclsRecursive(@import("semispace.zig"));
    // _ = testing.refAllDeclsRecursive(@import("sync.zig"));
}
