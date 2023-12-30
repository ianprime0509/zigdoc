const std = @import("std");
const Module = @import("Module.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var m = try Module.parse(allocator, "/var/home/ian/src/zig/lib/std/std.zig");
    defer m.deinit(allocator);
    std.debug.print("files {}\n", .{m.files.len});
    std.debug.print("decls {}\n", .{m.decls.len});

    for (m.declChildren(.root)) |decl| {
        const identifier = m.declIdentifier(decl) orelse "<unnamed>";
        switch (m.decls.items(.type)[@intFromEnum(decl)]) {
            .alias => std.debug.print("{s} = alias\n", .{identifier}),
            .alias_import => std.debug.print("{s} = alias-import\n", .{identifier}),
            .container => std.debug.print("{s} = container\n", .{identifier}),
            .import => std.debug.print("{s} = import {s}\n", .{ identifier, m.files.items(.path)[@intFromEnum(m.decls.items(.data)[@intFromEnum(decl)].import)] }),
            .other => std.debug.print("{s} = other\n", .{identifier}),
        }
    }
}
