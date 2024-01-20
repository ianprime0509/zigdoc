const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const assert = std.debug.assert;
const Document = @import("Document.zig");
const Node = Document.Node;
const StringIndex = Document.StringIndex;
const ExtraIndex = Document.ExtraIndex;

nodes: Node.List = .{},
string_bytes: std.ArrayListUnmanaged(u8) = .{},
extra: std.ArrayListUnmanaged(u32) = .{},
pending_blocks: std.ArrayListUnmanaged(Block) = .{},
scratch_string: std.ArrayListUnmanaged(u8) = .{},
scratch_extra: std.ArrayListUnmanaged(u32) = .{},
allocator: Allocator,

const Parser = @This();

const Block = struct {
    tag: Node.Tag,
    data: Data,
    string_start: usize,
    extra_start: usize,

    const Data = union {
        none: void,
        heading: struct {
            level: u3,
        },
        list: struct {
            kind: enum { ordered, @"-", @"*" },
            tight: bool,
            start: u30,
        },
        list_item: struct {
            indent: usize,
        },
        code: struct {
            tag: StringIndex,
            indent: usize,
            fence_len: usize,
        },
    };

    fn match(b: Block, line: []const u8) ?[]const u8 {
        const unindented = mem.trimLeft(u8, line, " \t");
        const indent = line.len - unindented.len;
        return switch (b.tag) {
            .paragraph => if (unindented.len > 0) unindented else null,
            .blockquote => if (mem.startsWith(u8, unindented, "> ")) unindented["> ".len..] else null,
            .heading => null,
            .list => line,
            .list_item => if (indent > b.data.list_item.indent) line[b.data.list_item.indent + 1 ..] else null,
            .code => code: {
                const trimmed = mem.trimRight(u8, unindented, " \t");
                if (mem.indexOfNone(u8, trimmed, "`") != null or trimmed.len != b.data.code.fence_len) {
                    const effective_indent = @min(indent, b.data.code.fence_len);
                    break :code line[effective_indent..];
                } else {
                    break :code null;
                }
            },
            .thematic_break => null,
            .root,
            .link,
            .image,
            .emphasis,
            .strong,
            .inline_code,
            .text,
            .line_break,
            => unreachable, // Not blocks
        };
    }
};

pub fn init(allocator: Allocator) Allocator.Error!Parser {
    var p: Parser = .{ .allocator = allocator };
    try p.nodes.append(allocator, .{
        .tag = .root,
        .data = undefined,
    });
    try p.string_bytes.append(allocator, 0);
    return p;
}

pub fn deinit(p: *Parser) void {
    p.nodes.deinit(p.allocator);
    p.string_bytes.deinit(p.allocator);
    p.extra.deinit(p.allocator);
    p.pending_blocks.deinit(p.allocator);
    p.scratch_string.deinit(p.allocator);
    p.scratch_extra.deinit(p.allocator);
    p.* = undefined;
}

pub fn feedLine(p: *Parser, line: []const u8) Allocator.Error!void {
    var rest_line = line;
    const first_unmatched = for (p.pending_blocks.items, 0..) |b, i| {
        if (b.match(rest_line)) |rest| {
            rest_line = rest;
        } else {
            break i;
        }
    } else p.pending_blocks.items.len;

    // New blocks cannot be started within a code block.
    var maybe_new_block = if (p.pending_blocks.items.len == 0 or p.pending_blocks.getLast().tag != .code)
        try p.startBlock(rest_line)
    else
        null;

    // This is a lazy continuation line if there are no new blocks to open and
    // the last open block is a paragraph.
    if (maybe_new_block == null and
        mem.indexOfNone(u8, rest_line, " \t") != null and
        p.pending_blocks.items.len > 0 and
        p.pending_blocks.getLast().tag == .paragraph)
    {
        try p.addScratchStringLine(rest_line);
        return;
    }

    // If a new block needs to be started, any paragraph needs to be closed,
    // even though this isn't detected as part of the closing condition for
    // paragraphs.
    if (maybe_new_block != null and
        p.pending_blocks.items.len > 0 and
        p.pending_blocks.getLast().tag == .paragraph)
    {
        try p.closeLastBlock();
    }

    while (p.pending_blocks.items.len > first_unmatched) {
        try p.closeLastBlock();
    }

    while (maybe_new_block) |new_block| : (maybe_new_block = try p.startBlock(rest_line)) {
        try p.pending_blocks.append(p.allocator, .{
            .tag = new_block.tag,
            .data = new_block.data,
            .string_start = p.scratch_string.items.len,
            .extra_start = p.scratch_extra.items.len,
        });
        // There may be more blocks to start within the same line.
        rest_line = new_block.rest;
    }

    rest_line = mem.trimLeft(u8, rest_line, " \t");

    if (rest_line.len > 0) {
        if (p.pending_blocks.items.len == 0 or
            p.pending_blocks.getLast().tag != .paragraph)
        {
            try p.pending_blocks.append(p.allocator, .{
                .tag = .paragraph,
                .data = .{ .none = {} },
                .string_start = p.scratch_string.items.len,
                .extra_start = p.scratch_extra.items.len,
            });
        }
        try p.addScratchStringLine(rest_line);
    }
}

pub fn feedLineInline(p: *Parser, line: []const u8) Allocator.Error!void {
    try p.addScratchStringLine(mem.trimLeft(u8, line, " \t"));
}

pub fn endInput(p: *Parser) Allocator.Error!Document {
    while (p.pending_blocks.items.len > 0) {
        try p.closeLastBlock();
    }
    try p.parseInlines(p.scratch_string.items);
    const children = try p.addExtraChildren(@ptrCast(p.scratch_extra.items));
    p.nodes.items(.data)[0] = .{ .container = .{ .children = children } };
    p.scratch_string.items.len = 0;
    p.scratch_extra.items.len = 0;

    const string_bytes = try p.string_bytes.toOwnedSlice(p.allocator);
    errdefer p.allocator.free(string_bytes);
    const extra = try p.extra.toOwnedSlice(p.allocator);
    errdefer p.allocator.free(extra);

    return .{
        .nodes = p.nodes.toOwnedSlice(),
        .string_bytes = string_bytes,
        .extra = extra,
    };
}

const NewBlock = struct {
    tag: Node.Tag,
    data: Block.Data,
    rest: []const u8,
};

fn startBlock(p: *Parser, line: []const u8) !?NewBlock {
    _ = p;
    if (isThematicBreak(line)) {
        return .{
            .tag = .thematic_break,
            .data = .{ .none = {} },
            .rest = "",
        };
    } else if (startBlockquote(line)) |rest| {
        return .{
            .tag = .blockquote,
            .data = .{ .none = {} },
            .rest = rest,
        };
    } else {
        // TODO: other block types
        return null;
    }
}

fn isThematicBreak(line: []const u8) bool {
    var char: ?u8 = null;
    var count: usize = 0;
    for (line) |b| {
        if (char) |c| {
            if (b == c) {
                count += 1;
            } else {
                return false;
            }
        } else switch (b) {
            '-', '_', '*' => char = b,
            ' ', '\t' => {},
            else => return false,
        }
    }
    return count >= 3;
}

fn startBlockquote(line: []const u8) ?[]const u8 {
    return for (line, 0..) |c, i| {
        switch (c) {
            ' ', '\t' => {},
            '>' => break line[i + 1 ..],
            else => break null,
        }
    } else null;
}

fn closeLastBlock(p: *Parser) !void {
    const b = p.pending_blocks.pop();
    const node = switch (b.tag) {
        .paragraph => paragraph: {
            try p.parseInlines(p.scratch_string.items[b.string_start..]);
            const children = try p.addExtraChildren(@ptrCast(p.scratch_extra.items[b.extra_start..]));
            break :paragraph try p.addNode(.{
                .tag = .paragraph,
                .data = .{ .container = .{
                    .children = children,
                } },
            });
        },
        .blockquote => blockquote: {
            const children = try p.addExtraChildren(@ptrCast(p.scratch_extra.items[b.extra_start..]));
            break :blockquote try p.addNode(.{
                .tag = .blockquote,
                .data = .{ .container = .{
                    .children = children,
                } },
            });
        },
        .heading => heading: {
            try p.parseInlines(p.scratch_string.items[b.string_start..]);
            const children = try p.addExtraChildren(@ptrCast(p.scratch_extra.items[b.extra_start..]));
            break :heading try p.addNode(.{
                .tag = .heading,
                .data = .{ .heading = .{
                    .level = b.data.heading.level,
                    .text = children,
                } },
            });
        },
        .list => list: {
            const children = try p.addExtraChildren(@ptrCast(p.scratch_extra.items[b.extra_start..]));
            break :list try p.addNode(.{
                .tag = .list,
                .data = .{ .list = .{
                    .ordered = b.data.list.kind == .ordered,
                    .tight = b.data.list.tight,
                    .start = b.data.list.start,
                    .children = children,
                } },
            });
        },
        .list_item => list_item: {
            const children = try p.addExtraChildren(@ptrCast(p.scratch_extra.items[b.extra_start..]));
            break :list_item try p.addNode(.{
                .tag = .list_item,
                .data = .{ .container = .{
                    .children = children,
                } },
            });
        },
        .code => code: {
            const content = try p.addString(p.scratch_string.items[b.string_start..]);
            break :code try p.addNode(.{
                .tag = .code,
                .data = .{ .code = .{
                    .tag = b.data.code.tag,
                    .content = content,
                } },
            });
        },
        .thematic_break => try p.addNode(.{
            .tag = .thematic_break,
            .data = .{ .none = {} },
        }),
        .root,
        .link,
        .image,
        .emphasis,
        .strong,
        .inline_code,
        .text,
        .line_break,
        => unreachable, // Not blocks
    };
    p.scratch_string.items.len = b.string_start;
    p.scratch_extra.items.len = b.extra_start;
    try p.scratch_extra.append(p.allocator, @intFromEnum(node));
}

fn parseInlines(p: *Parser, content: []const u8) !void {
    const string = try p.addString(mem.trimRight(u8, content, " \t\n"));
    const node = try p.addNode(.{
        .tag = .text,
        .data = .{ .text = .{
            .content = string,
        } },
    });
    try p.scratch_extra.append(p.allocator, @intFromEnum(node));
}

fn addNode(p: *Parser, node: Node) !Node.Index {
    const index: Node.Index = @enumFromInt(@as(u32, @intCast(p.nodes.len)));
    try p.nodes.append(p.allocator, node);
    return index;
}

fn addString(p: *Parser, s: []const u8) !StringIndex {
    const index: StringIndex = @enumFromInt(@as(u32, @intCast(p.string_bytes.items.len)));
    try p.string_bytes.ensureUnusedCapacity(p.allocator, s.len + 1);
    p.string_bytes.appendSliceAssumeCapacity(s);
    p.string_bytes.appendAssumeCapacity(0);
    return index;
}

fn addExtraChildren(p: *Parser, nodes: []const Node.Index) !ExtraIndex {
    const index: ExtraIndex = @enumFromInt(@as(u32, @intCast(p.extra.items.len)));
    try p.extra.ensureUnusedCapacity(p.allocator, nodes.len + 1);
    p.extra.appendAssumeCapacity(@intCast(nodes.len));
    p.extra.appendSliceAssumeCapacity(@ptrCast(nodes));
    return index;
}

fn addScratchStringLine(p: *Parser, line: []const u8) !void {
    try p.scratch_string.ensureUnusedCapacity(p.allocator, line.len + 1);
    p.scratch_string.appendSliceAssumeCapacity(line);
    p.scratch_string.appendAssumeCapacity('\n');
}
