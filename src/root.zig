//! By convention, root.zig is the root source file when making a library. If
//! you are making an executable, the convention is to delete this file and
//! start with main.zig instead.
const std = @import("std");
const testing = std.testing;

const semispace = @import("semispace.zig");

comptime {
    @setEvalBranchQuota(5000);

    _ = testing.refAllDeclsRecursive(@import("object.zig"));
    _ = testing.refAllDeclsRecursive(@import("semispace_tests.zig"));
    _ = testing.refAllDeclsRecursive(@import("types.zig"));
    _ = testing.refAllDeclsRecursive(@import("types_constructors.zig"));
    _ = testing.refAllDeclsRecursive(@import("semispace.zig"));
    _ = testing.refAllDeclsRecursive(@import("sync.zig"));
}
