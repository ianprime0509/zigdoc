const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const Ast = std.zig.Ast;
const assert = std.debug.assert;
const markdown = @import("markdown.zig");

files: File.List.Slice,
root_file: File.Index,
decls: Decl.List.Slice,
extra: []u32,

const Module = @This();

pub fn readFromTarGz(allocator: Allocator, root_path: []const u8, source_tar_gz_reader: anytype) !Module {
    var mod: Wip = .{ .allocator = allocator };
    defer mod.deinit();

    try mod.readFilesFromTarGz(root_path, source_tar_gz_reader);
    for (0..mod.files.len) |i| {
        try mod.parseFile(@enumFromInt(i));
    }

    return try mod.finish();
}

pub fn deinit(mod: *Module, allocator: Allocator) void {
    for (mod.files.items(.path)) |path| allocator.free(path);
    for (mod.files.items(.source)) |source| allocator.free(source);
    for (mod.files.items(.status), mod.files.items(.ast)) |status, *ast| {
        if (status == .parsed) ast.deinit(allocator);
    }
    for (mod.files.items(.imports)) |*imports| imports.deinit(allocator);
    mod.files.deinit(allocator);

    mod.decls.deinit(allocator);
    allocator.free(mod.extra);
    mod.* = undefined;
}

pub const OptionalExtraIndex = enum(u32) { none = std.math.maxInt(u32), _ };

pub const File = struct {
    status: Status,
    path: []u8,
    source: [:0]u8,
    ast: Ast,
    root_decl: Decl.Index,
    /// A map of `@import` builtin call nodes in `ast` to the files they import.
    ///
    /// Mapping the nodes directly to files avoids the need to check and process
    /// the `@import` builtin calls every time a lookup is required.
    imports: std.AutoHashMapUnmanaged(Ast.Node.Index, File.Index),

    pub const Index = enum(u32) { _ };
    pub const List = std.MultiArrayList(File);

    pub const Status = enum {
        invalid,
        source_available,
        parsed,
    };
};

pub fn filePath(mod: Module, file: File.Index) []const u8 {
    return mod.files.items(.path)[@intFromEnum(file)];
}

pub const Decl = struct {
    file: File.Index,
    /// The parent (container) of the decl. The root decl has itself as its
    /// parent.
    parent: Decl.Index,
    node: Ast.Node.Index,
    /// If the decl is a container, this will be a length `n` followed by `n`
    /// `Decl.Index`es for the children.
    children: OptionalExtraIndex,

    pub const Index = enum(u32) { root = 0, _ };
    pub const List = std.MultiArrayList(Decl);

    pub const Type = enum {
        namespace,
        container,
        function,
        value,
    };
};

pub fn declPublic(mod: Module, decl: Decl.Index) bool {
    const file = mod.decls.items(.file)[@intFromEnum(decl)];
    const ast = mod.files.items(.ast)[@intFromEnum(file)];
    const node = mod.decls.items(.node)[@intFromEnum(decl)];
    switch (ast.nodes.items(.tag)[node]) {
        .root => return true,
        .global_var_decl,
        .local_var_decl,
        .simple_var_decl,
        .aligned_var_decl,
        => {
            const var_decl = ast.fullVarDecl(node).?;
            const visib_token = var_decl.visib_token orelse return false;
            return ast.tokens.items(.tag)[visib_token] == .keyword_pub;
        },
        .fn_proto_simple,
        .fn_proto_multi,
        .fn_proto_one,
        .fn_proto,
        .fn_decl,
        => {
            var buf: [1]Ast.Node.Index = undefined;
            const fn_proto = ast.fullFnProto(&buf, node).?;
            const visib_token = fn_proto.visib_token orelse return false;
            return ast.tokens.items(.tag)[visib_token] == .keyword_pub;
        },
        else => unreachable,
    }
}

pub fn declType(mod: Module, decl: Decl.Index) Decl.Type {
    const file = mod.decls.items(.file)[@intFromEnum(decl)];
    const ast = mod.files.items(.ast)[@intFromEnum(file)];
    const node = mod.decls.items(.node)[@intFromEnum(decl)];
    const ast_tags = ast.nodes.items(.tag);
    switch (ast_tags[node]) {
        .root => {
            const has_fields = for (ast.rootDecls()) |d| {
                switch (ast_tags[d]) {
                    .container_field_init,
                    .container_field_align,
                    .container_field,
                    => break true,
                    else => {},
                }
            } else false;
            return if (has_fields) .container else .namespace;
        },
        .global_var_decl,
        .local_var_decl,
        .simple_var_decl,
        .aligned_var_decl,
        => {
            const var_decl = ast.fullVarDecl(node).?;
            if (var_decl.ast.init_node == 0) return .value;

            var buf: [2]Ast.Node.Index = undefined;
            if (ast.fullContainerDecl(&buf, var_decl.ast.init_node)) |container| {
                const has_fields = for (container.ast.members) |d| {
                    switch (ast_tags[d]) {
                        .container_field_init,
                        .container_field_align,
                        .container_field,
                        => break true,
                        else => {},
                    }
                } else false;
                return if (has_fields) .container else .namespace;
            } else {
                return .value;
            }
        },
        .fn_proto_simple,
        .fn_proto_multi,
        .fn_proto,
        .fn_decl,
        => return .function,
        else => unreachable,
    }
}

pub fn declName(mod: Module, decl: Decl.Index) ?[]const u8 {
    const file = mod.decls.items(.file)[@intFromEnum(decl)];
    const ast = mod.files.items(.ast)[@intFromEnum(file)];
    const node = mod.decls.items(.node)[@intFromEnum(decl)];
    return nodeIdentifier(ast, node);
}

pub fn declHasDoc(mod: Module, decl: Decl.Index) bool {
    const file = mod.decls.items(.file)[@intFromEnum(decl)];
    const ast = mod.files.items(.ast)[@intFromEnum(file)];
    const node = mod.decls.items(.node)[@intFromEnum(decl)];
    const token_tags = ast.tokens.items(.tag);

    switch (ast.nodes.items(.tag)[node]) {
        .root => return token_tags[0] == .container_doc_comment,
        .global_var_decl,
        .local_var_decl,
        .simple_var_decl,
        .aligned_var_decl,
        .fn_proto_simple,
        .fn_proto_multi,
        .fn_proto,
        .fn_decl,
        => {
            const first_token: Ast.TokenIndex = ast.firstToken(node);
            return first_token > 0 and token_tags[first_token - 1] == .doc_comment;
        },
        else => unreachable,
    }
}

/// Writes rendered documentation for `decl` to `writer`.
///
/// The documentation rendered is only that provided in doc comments directly
/// associated with `decl`. References to other decls are not followed.
pub fn declDoc(mod: Module, allocator: Allocator, decl: Decl.Index, writer: anytype) (Allocator.Error || @TypeOf(writer).Error)!void {
    const file = mod.decls.items(.file)[@intFromEnum(decl)];
    const ast = mod.files.items(.ast)[@intFromEnum(file)];
    const node = mod.decls.items(.node)[@intFromEnum(decl)];
    const token_tags = ast.tokens.items(.tag);

    var parser = try markdown.Parser.init(allocator);
    defer parser.deinit();
    switch (ast.nodes.items(.tag)[node]) {
        .root => {
            var token: Ast.TokenIndex = 0;
            while (token_tags[token] == .container_doc_comment) : (token += 1) {
                const contents = ast.tokenSlice(token)["//!".len..];
                try parser.feedLine(contents);
            }
        },
        .global_var_decl,
        .local_var_decl,
        .simple_var_decl,
        .aligned_var_decl,
        .fn_proto_simple,
        .fn_proto_multi,
        .fn_proto,
        .fn_decl,
        => {
            var token = ast.firstToken(node);
            while (token > 0 and token_tags[token - 1] == .doc_comment) {
                token -= 1;
            }
            while (token_tags[token] == .doc_comment) : (token += 1) {
                const contents = ast.tokenSlice(token)["///".len..];
                try parser.feedLine(contents);
            }
        },
        else => unreachable,
    }

    var doc = try parser.endInput();
    defer doc.deinit(allocator);
    try doc.render(writer);
}

/// Like `declDoc`, but renders only the documentation summary (the
/// documentation up to and including the first period followed by some form of
/// space).
pub fn declDocSummary(
    mod: Module,
    allocator: Allocator,
    decl: Decl.Index,
    writer: anytype,
) (Allocator.Error || @TypeOf(writer).Error)!void {
    const file = mod.decls.items(.file)[@intFromEnum(decl)];
    const ast = mod.files.items(.ast)[@intFromEnum(file)];
    const node = mod.decls.items(.node)[@intFromEnum(decl)];
    const token_tags = ast.tokens.items(.tag);

    var parser = try markdown.Parser.init(allocator);
    defer parser.deinit();
    switch (ast.nodes.items(.tag)[node]) {
        .root => {
            var token: Ast.TokenIndex = 0;
            while (token_tags[token] == .container_doc_comment) : (token += 1) {
                const contents = ast.tokenSlice(token)["//!".len..];
                if (indexOfSummaryEnd(contents)) |end| {
                    try parser.feedLineInline(contents[0..end]);
                    break;
                } else {
                    try parser.feedLineInline(contents);
                }
            }
        },
        .global_var_decl,
        .local_var_decl,
        .simple_var_decl,
        .aligned_var_decl,
        .fn_proto_simple,
        .fn_proto_multi,
        .fn_proto,
        .fn_decl,
        => {
            var token: Ast.TokenIndex = ast.firstToken(node);
            while (token > 0 and token_tags[token - 1] == .doc_comment) {
                token -= 1;
            }
            while (token_tags[token] == .doc_comment) : (token += 1) {
                const contents = ast.tokenSlice(token)["///".len..];
                if (indexOfSummaryEnd(contents)) |end| {
                    try parser.feedLineInline(contents[0..end]);
                    break;
                } else {
                    try parser.feedLineInline(contents);
                }
            }
        },
        else => unreachable,
    }

    var document = try parser.endInput();
    defer document.deinit(allocator);
    try document.render(writer);
}

/// Substrings that might look like the end of a sentence, but aren't.
const false_summary_ends: []const []const u8 = &.{
    "e.g.",
    "i.e.",
};

fn indexOfSummaryEnd(line: []const u8) ?usize {
    var start: usize = 0;
    return while (mem.indexOfScalarPos(u8, line, start, '.')) |index| {
        if (index == line.len - 1 or std.ascii.isWhitespace(line[index + 1])) {
            for (false_summary_ends) |false_summary_end| {
                if (mem.endsWith(u8, line[0 .. index + 1], false_summary_end)) break;
            } else break index + 1;
        }
        start = index + 1;
    } else null;
}

pub fn declChildren(mod: Module, decl: Decl.Index) []const Decl.Index {
    const children = mod.decls.items(.children)[@intFromEnum(decl)];
    if (children == .none) return &.{};
    const len = mod.extra[@intFromEnum(children)];
    return @ptrCast(mod.extra[@intFromEnum(children) + 1 ..][0..len]);
}

/// Looks up a child of `decl` by name.
pub fn declChild(mod: Module, decl: Decl.Index, name: []const u8) ?Decl.Index {
    const file = mod.decls.items(.file)[@intFromEnum(decl)];
    const ast = mod.files.items(.ast)[@intFromEnum(file)];
    const children = mod.declChildren(decl);

    const Context = struct { ast: Ast, decls: Decl.List.Slice };
    const index = std.sort.binarySearch(Decl.Index, name, children, Context{ .ast = ast, .decls = mod.decls }, struct {
        fn order(ctx: Context, key: []const u8, mid_item: Decl.Index) std.math.Order {
            const nodes = ctx.decls.items(.node);
            const mid_name = nodeIdentifier(ctx.ast, nodes[@intFromEnum(mid_item)]) orelse return .lt;
            // TODO: consider quoted identifiers
            return mem.order(u8, key, mid_name);
        }
    }.order) orelse return null;
    return children[index];
}

/// Resolves a name in the context of `decl` (that is, looks it up in any parent
/// scope).
pub fn declResolve(mod: Module, decl: Decl.Index, name: []const u8) ?Decl.Index {
    const parents = mod.decls.items(.parent);
    var current_decl = parents[@intFromEnum(decl)];
    while (true) {
        if (mod.declChild(current_decl, name)) |child| return child;
        const parent = parents[@intFromEnum(decl)];
        if (parent == current_decl) return null;
        current_decl = parent;
    }
}

/// Resolves the value of `node` within `ast` to a decl. The resolution starts
/// in the context (parent) of `decl`.
pub fn declResolveNode(mod: Module, decl: Decl.Index, ast: Ast, node: Ast.Node.Index) ?Decl.Index {
    switch (ast.nodes.items(.tag)[node]) {
        .identifier => {
            const name = ast.tokenSlice(ast.nodes.items(.main_token)[node]);
            const resolved = mod.declResolve(decl, name) orelse return null;
            return mod.declResolveSelfFull(resolved);
        },
        .builtin_call_two, .builtin_call_two_comma => {
            const file = mod.decls.items(.file)[@intFromEnum(decl)];
            const imports = mod.files.items(.imports)[@intFromEnum(file)];
            const imported_file = imports.get(node) orelse return null;
            return mod.files.items(.root_decl)[@intFromEnum(imported_file)];
        },
        .field_access => {
            const data = ast.nodes.items(.data)[node];
            const lhs_resolved = mod.declResolveNode(decl, ast, data.lhs) orelse return null;
            const rhs_name = ast.tokenSlice(data.rhs);
            const resolved = mod.declChild(lhs_resolved, rhs_name) orelse return null;
            return mod.declResolveSelfFull(resolved);
        },
        else => return null,
    }
}

/// A shortcut for `declResolveNode` when the node to be resolved is the
/// initialization expression of `decl`.
pub fn declResolveSelf(mod: Module, decl: Decl.Index) ?Decl.Index {
    const file = mod.decls.items(.file)[@intFromEnum(decl)];
    const ast = mod.files.items(.ast)[@intFromEnum(file)];
    const node = mod.decls.items(.node)[@intFromEnum(decl)];
    switch (ast.nodes.items(.tag)[node]) {
        .global_var_decl,
        .local_var_decl,
        .simple_var_decl,
        .aligned_var_decl,
        => {
            const var_decl = ast.fullVarDecl(node).?;
            if (var_decl.ast.init_node == 0) return null;
            return mod.declResolveNode(decl, ast, var_decl.ast.init_node);
        },
        else => return null,
    }
}

/// Repeatedly calls `declResolveSelf` until no further resolution is possible,
/// returning the last resolved decl.
pub fn declResolveSelfFull(mod: Module, decl: Decl.Index) Decl.Index {
    var current = decl;
    while (true) {
        const resolved = mod.declResolveSelf(current);
        current = resolved orelse return current;
    }
}

const Wip = struct {
    files: File.List = .{},
    files_by_path: std.StringHashMapUnmanaged(File.Index) = .{},
    root_file: File.Index = undefined,
    decls: Decl.List = .{},
    extra: std.ArrayListUnmanaged(u32) = .{},
    scratch: std.ArrayListUnmanaged(u32) = .{},
    allocator: Allocator,

    fn deinit(mod: *Wip) void {
        for (mod.files.items(.path)) |path| mod.allocator.free(path);
        for (mod.files.items(.source)) |source| mod.allocator.free(source);
        for (mod.files.items(.status), mod.files.items(.ast)) |status, *ast| {
            if (status == .parsed) ast.deinit(mod.allocator);
        }
        for (mod.files.items(.imports)) |*imports| imports.deinit(mod.allocator);
        mod.files.deinit(mod.allocator);

        mod.files_by_path.deinit(mod.allocator);
        mod.decls.deinit(mod.allocator);
        mod.extra.deinit(mod.allocator);
        mod.scratch.deinit(mod.allocator);
        mod.* = undefined;
    }

    fn finish(mod: *Wip) !Module {
        return .{
            .files = mod.files.toOwnedSlice(),
            .root_file = mod.root_file,
            .decls = mod.decls.toOwnedSlice(),
            .extra = try mod.extra.toOwnedSlice(mod.allocator),
        };
    }

    fn readFilesFromTarGz(
        mod: *Wip,
        root_path: []const u8,
        source_tar_gz_reader: anytype,
    ) !void {
        var decompress = try std.compress.gzip.decompress(mod.allocator, source_tar_gz_reader);
        defer decompress.deinit();
        var tar_iter = std.tar.iterator(decompress.reader(), null);

        while (try tar_iter.next()) |file| {
            switch (file.kind) {
                .directory => {},
                .normal => {
                    if (file.size == 0 and file.name.len == 0) break;
                    const file_path = try std.fs.path.resolvePosix(mod.allocator, &.{ ".", file.name });
                    errdefer mod.allocator.free(file_path);

                    var source_wip = std.ArrayList(u8).init(mod.allocator);
                    defer source_wip.deinit();
                    try file.write(source_wip.writer());
                    const source = try source_wip.toOwnedSliceSentinel(0);
                    errdefer mod.allocator.free(source);

                    const file_index: File.Index = @enumFromInt(@as(u32, @intCast(mod.files.len)));
                    try mod.files_by_path.put(mod.allocator, file_path, file_index);
                    try mod.files.append(mod.allocator, .{
                        .status = .source_available,
                        .path = file_path,
                        .source = source,
                        .ast = undefined,
                        .root_decl = undefined,
                        .imports = .{},
                    });
                },
                else => return error.InvalidTar,
            }
        }

        mod.root_file = mod.files_by_path.get(root_path) orelse return error.InvalidRootPath;
    }

    pub fn parseFile(mod: *Wip, file: File.Index) !void {
        const status = &mod.files.items(.status)[@intFromEnum(file)];
        if (status.* != .source_available) return;
        // The status will remain invalid until parsing is completely done.
        status.* = .invalid;

        const source = mod.files.items(.source)[@intFromEnum(file)];
        var ast = try Ast.parse(mod.allocator, source, .zig);
        defer if (status.* == .invalid) ast.deinit(mod.allocator);
        if (ast.errors.len != 0) return;

        mod.files.items(.ast)[@intFromEnum(file)] = ast;
        try mod.processImports(file);
        _ = try mod.processDecl(file, undefined, 0);

        status.* = .parsed;
    }

    fn processImports(mod: *Wip, file: File.Index) !void {
        const file_path = mod.files.items(.path)[@intFromEnum(file)];
        const ast = mod.files.items(.ast)[@intFromEnum(file)];
        const tags = ast.nodes.items(.tag);
        const main_tokens = ast.nodes.items(.main_token);
        const datas = ast.nodes.items(.data);
        const imports = &mod.files.items(.imports)[@intFromEnum(file)];
        for (tags, 0..) |tag, i| {
            switch (tag) {
                .builtin_call_two, .builtin_call_two_comma => {
                    const builtin_name = ast.tokenSlice(main_tokens[i]);
                    if (!mem.eql(u8, builtin_name, "@import")) continue;
                    if (datas[i].lhs == 0 or datas[i].rhs != 0) continue;
                    if (tags[datas[i].lhs] != .string_literal) continue;
                    const import_path_raw = ast.tokenSlice(main_tokens[datas[i].lhs]);
                    const import_path = std.zig.string_literal.parseAlloc(mod.allocator, import_path_raw) catch |err| switch (err) {
                        error.OutOfMemory => return error.OutOfMemory,
                        error.InvalidLiteral => continue,
                    };
                    defer mod.allocator.free(import_path);
                    const resolved_path = try std.fs.path.resolvePosix(mod.allocator, &.{ file_path, "..", import_path });
                    defer mod.allocator.free(resolved_path);
                    if (mod.files_by_path.get(resolved_path)) |imported_file| {
                        try imports.put(mod.allocator, @intCast(i), imported_file);
                    }
                },
                else => {},
            }
        }
    }

    fn processDecl(
        mod: *Wip,
        file: File.Index,
        parent: Decl.Index,
        node: Ast.Node.Index,
    ) !?Decl.Index {
        const ast = mod.files.items(.ast)[@intFromEnum(file)];
        switch (ast.nodes.items(.tag)[node]) {
            .root => {
                assert(node == 0);
                const index = try mod.appendDecl(.{
                    .file = file,
                    .parent = @enumFromInt(@as(u32, @intCast(mod.decls.len))),
                    .node = node,
                    .children = undefined,
                });
                mod.files.items(.root_decl)[@intFromEnum(file)] = index;

                const scratch_top = mod.scratch.items.len;
                defer mod.scratch.shrinkRetainingCapacity(scratch_top);
                try mod.scratch.append(mod.allocator, undefined); // length
                for (ast.rootDecls()) |child| {
                    const decl_index = try mod.processDecl(file, index, child) orelse continue;
                    try mod.scratch.append(mod.allocator, @intFromEnum(decl_index));
                }
                mod.scratch.items[scratch_top] = @intCast(mod.scratch.items.len - scratch_top - 1);
                mod.sortDecls(ast, @ptrCast(mod.scratch.items[scratch_top + 1 ..]));
                mod.decls.items(.children)[@intFromEnum(index)] = try mod.encodeScratch(scratch_top);

                return index;
            },
            .@"usingnamespace" => return null, // TODO
            .test_decl => return null, // TODO: doctests
            .global_var_decl,
            .local_var_decl,
            .simple_var_decl,
            .aligned_var_decl,
            => {
                const var_decl = ast.fullVarDecl(node).?;
                // Do not include private decls
                const visib_token = var_decl.visib_token orelse return null;
                if (ast.tokens.items(.tag)[visib_token] != .keyword_pub) return null;

                const index = try mod.appendDecl(.{
                    .file = file,
                    .parent = parent,
                    .node = node,
                    .children = .none,
                });
                if (var_decl.ast.init_node == 0) return index;

                var buf: [2]Ast.Node.Index = undefined;
                if (ast.fullContainerDecl(&buf, var_decl.ast.init_node)) |container| {
                    const scratch_top = mod.scratch.items.len;
                    defer mod.scratch.shrinkRetainingCapacity(scratch_top);
                    try mod.scratch.append(mod.allocator, undefined); // length
                    for (container.ast.members) |member| {
                        const child_index = try mod.processDecl(file, index, member) orelse continue;
                        try mod.scratch.append(mod.allocator, @intFromEnum(child_index));
                    }
                    mod.scratch.items[scratch_top] = @intCast(mod.scratch.items.len - scratch_top - 1);
                    mod.sortDecls(ast, @ptrCast(mod.scratch.items[scratch_top + 1 ..]));
                    mod.decls.items(.children)[@intFromEnum(index)] = try mod.encodeScratch(scratch_top);
                }

                return index;
            },
            .fn_proto_simple,
            .fn_proto_multi,
            .fn_proto_one,
            .fn_proto,
            .fn_decl,
            => {
                var buf: [1]Ast.Node.Index = undefined;
                const fn_proto = ast.fullFnProto(&buf, node).?;
                // Do not include private decls
                const visib_token = fn_proto.visib_token orelse return null;
                if (ast.tokens.items(.tag)[visib_token] != .keyword_pub) return null;

                return try mod.appendDecl(.{
                    .file = file,
                    .parent = parent,
                    .node = node,
                    .children = .none,
                });
            },
            else => return null,
        }
    }

    fn appendDecl(mod: *Wip, decl: Decl) !Decl.Index {
        const index: Decl.Index = @enumFromInt(@as(u32, @intCast(mod.decls.len)));
        try mod.decls.append(mod.allocator, decl);
        return index;
    }

    fn sortDecls(mod: *Wip, ast: Ast, decl_indexes: []Decl.Index) void {
        const Context = struct { ast: Ast, decls: Decl.List.Slice };
        mem.sort(Decl.Index, decl_indexes, Context{ .ast = ast, .decls = mod.decls.slice() }, struct {
            fn lessThan(ctx: Context, a: Decl.Index, b: Decl.Index) bool {
                const nodes = ctx.decls.items(.node);
                const a_name = nodeIdentifier(ctx.ast, nodes[@intFromEnum(a)]);
                const b_name = nodeIdentifier(ctx.ast, nodes[@intFromEnum(b)]);
                if (a_name == null) return b_name != null;
                if (b_name == null) return false;
                // TODO: consider quoted identifiers
                return mem.lessThan(u8, a_name.?, b_name.?);
            }
        }.lessThan);
    }

    fn encodeScratch(mod: *Wip, scratch_top: usize) !OptionalExtraIndex {
        const index: OptionalExtraIndex = @enumFromInt(@as(u32, @intCast(mod.extra.items.len)));
        try mod.extra.appendSlice(mod.allocator, mod.scratch.items[scratch_top..]);
        return index;
    }
};

fn nodeIdentifier(ast: Ast, node: Ast.Node.Index) ?[]const u8 {
    const name_token = switch (ast.nodes.items(.tag)[node]) {
        .global_var_decl,
        .local_var_decl,
        .simple_var_decl,
        .aligned_var_decl,
        .fn_proto_simple,
        .fn_proto_multi,
        .fn_proto_one,
        .fn_proto,
        => ast.nodes.items(.main_token)[node] + 1,
        .fn_decl => token: {
            const fn_proto = ast.nodes.items(.data)[node].lhs;
            break :token ast.nodes.items(.main_token)[fn_proto] + 1;
        },
        else => return null,
    };
    assert(ast.tokens.items(.tag)[name_token] == .identifier);
    return ast.tokenSlice(name_token);
}
