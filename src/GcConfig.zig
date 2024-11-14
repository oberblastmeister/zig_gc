const std = @import("std");

const object = @import("object.zig");
const Header = object.Header;
const InfoTable = object.InfoTable;

objectSize: fn (object: *Header) usize,
processFields: fn (gc: *anyopaque, ref: *Header, processField: fn (gc: *anyopaque, **Header) void) void,
