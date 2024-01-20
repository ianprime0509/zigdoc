const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;

nodes: Node.List.Slice,
string_bytes: []u8,
extra: []u32,

const Document = @This();

pub const Node = struct {
    tag: Tag,
    data: Data,

    pub const Index = enum(u32) { root = 0, _ };
    pub const List = std.MultiArrayList(Node);

    pub const Tag = enum {
        /// `data` is `container`.
        root,

        // Block
        /// `data` is `container`.
        paragraph,
        /// `data` is `container`.
        blockquote,
        /// `data` is `heading`.
        heading,
        /// `data` is `list`.
        list,
        /// `data` is `container`.
        list_item,
        /// `data` is `code`.
        code,
        /// `data` is `none`.
        thematic_break,

        // Inline
        /// `data` is `link`.
        link,
        /// `data` is `link`.
        image,
        /// `data` is `container`.
        emphasis,
        /// `data` is `container`.
        strong,
        /// `data` is `text`.
        inline_code,
        /// `data` is `text`.
        text,
        /// `data` is `none`.
        line_break,
    };

    pub const Data = union {
        none: void,
        container: struct {
            /// Points to `Children`.
            children: ExtraIndex,
        },
        heading: struct {
            /// Must be between 1 and 6, inclusive.
            level: u3,
            /// Points to `Children`.
            text: ExtraIndex,
        },
        list: struct {
            ordered: bool,
            tight: bool,
            start: u30,
            /// Points to `Children`.
            children: ExtraIndex,
        },
        code: struct {
            tag: StringIndex,
            content: StringIndex,
        },
        link: struct {
            /// Points to `Children`.
            text: ExtraIndex,
            destination: StringIndex,
        },
        text: struct {
            content: StringIndex,
        },
    };

    /// Trailing: `len` `Node.Index`
    pub const Children = struct {
        len: u32,
    };
};

pub const ExtraIndex = enum(u32) { _ };

pub const StringIndex = enum(u32) { empty = 0, _ };

pub fn deinit(d: *Document, allocator: Allocator) void {
    d.nodes.deinit(allocator);
    allocator.free(d.string_bytes);
    allocator.free(d.extra);
    d.* = undefined;
}

pub fn string(d: Document, index: StringIndex) [:0]const u8 {
    const start = @intFromEnum(index);
    return mem.span(@as([*:0]u8, @ptrCast(d.string_bytes[start..].ptr)));
}

fn ExtraData(comptime T: type) type {
    return struct { data: T, end: usize };
}

pub fn extraData(d: Document, comptime T: type, index: ExtraIndex) ExtraData(T) {
    const fields = @typeInfo(T).Struct.fields;
    var i: usize = @intFromEnum(index);
    var result: T = undefined;
    inline for (fields) |field| {
        @field(result, field.name) = switch (field.type) {
            u32 => d.extra[i],

            else => @compileError("bad field type"),
        };
        i += 1;
    }
    return .{ .data = result, .end = i };
}

pub fn extraChildren(d: Document, index: ExtraIndex) []const Node.Index {
    const children = d.extraData(Node.Children, index);
    return @ptrCast(d.extra[children.end..][0..children.data.len]);
}

pub fn render(d: Document, writer: anytype) @TypeOf(writer).Error!void {
    try d.renderNode(.root, writer, false);
}

fn renderNode(d: Document, node: Node.Index, writer: anytype, tight_paragraphs: bool) !void {
    const data = d.nodes.items(.data)[@intFromEnum(node)];
    switch (d.nodes.items(.tag)[@intFromEnum(node)]) {
        .root => {
            for (d.extraChildren(data.container.children)) |child| {
                try d.renderNode(child, writer, false);
            }
        },
        .paragraph => {
            if (!tight_paragraphs) {
                try writer.writeAll("<p>");
            }
            for (d.extraChildren(data.container.children)) |child| {
                try d.renderNode(child, writer, false);
            }
            if (!tight_paragraphs) {
                try writer.writeAll("</p>\n");
            }
        },
        .blockquote => {
            try writer.writeAll("<blockquote>");
            for (d.extraChildren(data.container.children)) |child| {
                try d.renderNode(child, writer, false);
            }
            try writer.writeAll("</blockquote>\n");
        },
        .heading => {
            try writer.print("<h{}>", .{data.heading.level});
            for (d.extraChildren(data.container.children)) |child| {
                try d.renderNode(child, writer, false);
            }
            try writer.print("</h{}>\n", .{data.heading.level});
        },
        .list => {
            if (data.list.ordered) {
                if (data.list.start != 1) {
                    try writer.print("<ol start=\"{}\">", .{data.list.start});
                } else {
                    try writer.writeAll("<ol>\n");
                }
            } else {
                try writer.writeAll("<ul>\n");
            }
            for (d.extraChildren(data.container.children)) |child| {
                try d.renderNode(child, writer, data.list.tight);
            }
            if (data.list.ordered) {
                try writer.writeAll("</ol>\n");
            } else {
                try writer.writeAll("</ul>\n");
            }
        },
        .list_item => {
            try writer.writeAll("<li>");
            for (d.extraChildren(data.container.children)) |child| {
                try d.renderNode(child, writer, tight_paragraphs);
            }
            try writer.writeAll("</li>\n");
        },
        .code => {
            // TODO: handle code tag
            try writer.writeAll("<pre><code>");
            try d.renderText(data.code.content, writer);
            try writer.writeAll("</code></pre>\n");
        },
        .thematic_break => {
            try writer.writeAll("<hr />\n");
        },
        .link => {
            try writer.writeAll("<a href=\"");
            try d.renderText(data.link.destination, writer);
            try writer.writeAll("\">");
            for (d.extraChildren(data.link.text)) |child| {
                try d.renderNode(child, writer, false);
            }
            try writer.writeAll("</a>");
        },
        .image => {
            try writer.writeAll("<img src=\"");
            try d.renderText(data.link.destination, writer);
            try writer.writeAll("\" alt=\"");
            for (d.extraChildren(data.link.text)) |child| {
                try d.renderInlineNodeText(child, writer);
            }
            try writer.writeAll("\" />");
        },
        .emphasis => {
            try writer.writeAll("<em>");
            for (d.extraChildren(data.container.children)) |child| {
                try d.renderNode(child, writer, false);
            }
            try writer.writeAll("</em>");
        },
        .strong => {
            try writer.writeAll("<strong>");
            for (d.extraChildren(data.container.children)) |child| {
                try d.renderNode(child, writer, false);
            }
            try writer.writeAll("</strong>");
        },
        .inline_code => {
            try writer.writeAll("<code>");
            try d.renderText(data.text.content, writer);
            try writer.writeAll("</code>");
        },
        .text => {
            try d.renderText(data.text.content, writer);
        },
        .line_break => {
            try writer.writeAll("<br />\n");
        },
    }
}

/// Renders only the text content of an inline node.
fn renderInlineNodeText(d: Document, node: Node.Index, writer: anytype) !void {
    const data = d.nodes.items(.data)[@intFromEnum(node)];
    switch (d.nodes.items(.tag)[@intFromEnum(node)]) {
        .root,
        .paragraph,
        .blockquote,
        .heading,
        .list,
        .list_item,
        .code,
        .thematic_break,
        => unreachable, // Blocks
        .link, .image => {
            for (d.extraChildren(data.link.text)) |child| {
                try d.renderInlineNodeText(child, writer);
            }
        },
        .emphasis, .strong => {
            for (d.extraChildren(data.container.children)) |child| {
                try d.renderInlineNodeText(child, writer);
            }
        },
        .inline_code, .text => {
            try d.renderText(data.text.content, writer);
        },
        .line_break => {
            try writer.writeByte(' ');
        },
    }
}

fn renderText(d: Document, index: StringIndex, writer: anytype) !void {
    const text = d.string(index);
    for (text) |c| {
        switch (c) {
            '<' => try writer.writeAll("&lt;"),
            '>' => try writer.writeAll("&gt;"),
            '\'' => try writer.writeAll("&apos;"),
            '"' => try writer.writeAll("&quot;"),
            '&' => try writer.writeAll("&amp;"),
            else => try writer.writeByte(c),
        }
    }
}
