pub const Document = @import("markdown/Document.zig");
pub const Parser = @import("markdown/Parser.zig");

pub fn main() !void {
    const std = @import("std");
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const md =
        \\Hello, world!
        \\Test & test
        \\
        \\*Emphasis **strong***
        \\
        \\Test
        \\> Hi
        \\Bye
        \\
        \\- Item 1
    ;

    var parser = try Parser.init(allocator);
    defer parser.deinit();
    var lines = std.mem.splitScalar(u8, md, '\n');
    while (lines.next()) |line| {
        try parser.feedLine(line);
    }
    var doc = try parser.endInput();
    defer doc.deinit(allocator);

    var stdout = std.io.bufferedWriter(std.io.getStdOut().writer());
    try doc.render(stdout.writer());
    try stdout.writer().writeByte('\n');
    try stdout.flush();
}
