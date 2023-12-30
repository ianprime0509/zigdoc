const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const Ast = std.zig.Ast;
const assert = std.debug.assert;

files: File.List.Slice,
decls: Decl.List.Slice,
extra: []u32,

const Module = @This();

pub const File = struct {
    path: []u8,
    source: [:0]u8,
    ast: Ast,
    root_decl: Decl.Index,

    pub const List = std.MultiArrayList(File);
    pub const Index = enum(u32) { _ };
};

pub const Decl = struct {
    type: Type,
    file: File.Index,
    node: Ast.Node.Index,
    data: Data,

    pub const List = std.MultiArrayList(Decl);
    pub const Index = enum(u32) { root = 0, _ };

    pub const Type = enum(u8) {
        /// `data` is `alias`.
        alias,
        /// `data` is `alias_import`.
        alias_import,
        /// `data` is `container`.
        container,
        /// `data` is `import`.
        import,
        /// `data` is `none`.
        other,
    };

    pub const Data = union {
        none: void,
        /// Extra data is `len` followed by `[len]TokenIndex`.
        /// The tokens are identifiers, in the order they should be traversed.
        alias: ExtraIndex,
        /// Like `alias`, but the extra data is additionally followed by a
        /// `Decl.Index` representing the `@import` at the beginning of the
        /// chain.
        alias_import: ExtraIndex,
        /// Extra data is `len` followed by `[len]Decl.Index`.
        container: ExtraIndex,
        import: File.Index,
    };
};

pub const ExtraIndex = enum(u32) { _ };

pub fn deinit(m: *Module, allocator: Allocator) void {
    for (m.files.items(.path)) |path| allocator.free(path);
    for (m.files.items(.source)) |source| allocator.free(source);
    for (m.files.items(.ast)) |*ast| ast.deinit(allocator);
    m.files.deinit(allocator);
    m.decls.deinit(allocator);
    allocator.free(m.extra);
    m.* = undefined;
}

pub fn parse(allocator: Allocator, root_file_path: []const u8) !Module {
    var wip = try Wip.init(allocator, std.fs.path.dirname(root_file_path) orelse return error.InvalidRootPath);
    defer wip.deinit();
    try wip.discoverFiles(std.fs.path.basename(root_file_path));
    try wip.analyze();
    return wip.toModule();
}

pub fn declChildren(m: Module, decl: Decl.Index) []const Decl.Index {
    const extra_index = @intFromEnum(m.decls.items(.data)[@intFromEnum(decl)].container);
    const len = m.extra[extra_index];
    return @ptrCast(m.extra[extra_index + 1 ..][0..len]);
}

pub fn declIdentifier(m: Module, decl: Decl.Index) ?[]const u8 {
    const file = m.decls.items(.file)[@intFromEnum(decl)];
    const ast = m.files.items(.ast)[@intFromEnum(file)];
    const node = m.decls.items(.node)[@intFromEnum(decl)];
    return nodeIdentifier(ast, node);
}

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

const Wip = struct {
    root_dir: std.fs.Dir,
    files: File.List = .{},
    /// Key memory managed by `path` in `files`.
    files_by_path: std.StringHashMapUnmanaged(File.Index) = .{},
    decls: Decl.List = .{},
    extra: std.ArrayListUnmanaged(u32) = .{},
    scratch: std.ArrayListUnmanaged(u32) = .{},
    allocator: Allocator,

    fn init(allocator: Allocator, root_dir_path: []const u8) !Wip {
        var root_dir = try std.fs.cwd().openDir(root_dir_path, .{ .iterate = true });
        errdefer root_dir.close();

        return .{
            .root_dir = root_dir,
            .allocator = allocator,
        };
    }

    fn deinit(m: *Wip) void {
        m.root_dir.close();
        for (m.files.items(.path)) |path| m.allocator.free(path);
        for (m.files.items(.source)) |source| m.allocator.free(source);
        for (m.files.items(.ast)) |*ast| ast.deinit(m.allocator);
        m.files.deinit(m.allocator);
        m.files_by_path.deinit(m.allocator);
        m.decls.deinit(m.allocator);
        m.extra.deinit(m.allocator);
        m.scratch.deinit(m.allocator);
        m.* = undefined;
    }

    fn discoverFiles(m: *Wip, file_name: []const u8) !void {
        const ast = ast: {
            const path = try m.allocator.dupe(u8, file_name);
            errdefer m.allocator.free(path);
            const source = try m.root_dir.readFileAllocOptions(m.allocator, path, std.math.maxInt(u32), null, @alignOf(u8), 0);
            errdefer m.allocator.free(source);
            var ast = try Ast.parse(m.allocator, source, .zig);
            errdefer ast.deinit(m.allocator);
            if (ast.errors.len > 0) return error.ParseError; // TODO: report errors
            try m.files_by_path.put(m.allocator, path, @enumFromInt(@as(u32, @intCast(m.files.len))));
            try m.files.append(m.allocator, .{
                .path = path,
                .source = source,
                .ast = ast,
                .root_decl = undefined,
            });
            break :ast ast;
        };

        for (0..ast.nodes.len) |i| {
            if (try m.importPath(file_name, ast, @intCast(i))) |imported_path| {
                defer m.allocator.free(imported_path);
                if (!m.files_by_path.contains(imported_path)) {
                    try m.discoverFiles(imported_path);
                }
            }
        }
    }

    fn analyze(m: *Wip) !void {
        for (m.files.items(.ast), 0..) |ast, i| {
            const file_index: File.Index = @enumFromInt(@as(u32, @intCast(i)));
            assert(try m.processDecl(file_index, ast, 0) != null);
        }
    }

    fn toModule(m: *Wip) !Module {
        var files = m.files.toOwnedSlice();
        errdefer files.deinit(m.allocator);
        var decls = m.decls.toOwnedSlice();
        errdefer decls.deinit(m.allocator);
        const extra = try m.extra.toOwnedSlice(m.allocator);
        errdefer m.allocator.free(extra);

        return .{ .files = files, .decls = decls, .extra = extra };
    }

    fn importPath(m: *Wip, current_path: []const u8, ast: Ast, node: Ast.Node.Index) !?[]u8 {
        const token_tags = ast.tokens.items(.tag);
        const tags = ast.nodes.items(.tag);
        const main_tokens = ast.nodes.items(.main_token);
        const datas = ast.nodes.items(.data);
        if (tags[node] != .builtin_call_two) return null;

        const builtin_name = ast.tokenSlice(main_tokens[node]);
        const data = datas[node];
        if (!mem.eql(u8, builtin_name, "@import") or
            data.lhs == 0 or
            data.rhs != 0 or
            token_tags[main_tokens[data.lhs]] != .string_literal)
        {
            return null;
        }
        const import_path = std.zig.string_literal.parseAlloc(m.allocator, ast.tokenSlice(main_tokens[data.lhs])) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidLiteral => return null,
        };
        defer m.allocator.free(import_path);

        return if (mem.eql(u8, import_path, "builtin") or mem.eql(u8, import_path, "root") or mem.eql(u8, import_path, "build_options"))
            null
        else if (mem.eql(u8, import_path, "std"))
            try m.allocator.dupe(u8, "std.zig") // TODO: don't hard-code this
        else
            try std.fs.path.resolve(m.allocator, &.{ current_path, "..", import_path });
    }

    fn processDecl(m: *Wip, file_index: File.Index, ast: Ast, node: Ast.Node.Index) !?Decl.Index {
        switch (ast.nodes.items(.tag)[node]) {
            .root => {
                assert(node == 0);
                const index = try m.appendDecl(.{
                    .type = .container,
                    .file = file_index,
                    .node = node,
                    .data = undefined,
                });
                m.files.items(.root_decl)[@intFromEnum(file_index)] = index;

                const scratch_top = m.scratch.items.len;
                defer m.scratch.shrinkRetainingCapacity(scratch_top);
                try m.scratch.append(m.allocator, undefined); // length
                for (ast.rootDecls()) |child| {
                    const decl_index = try m.processDecl(file_index, ast, child) orelse continue;
                    try m.scratch.append(m.allocator, @intFromEnum(decl_index));
                }
                m.scratch.items[scratch_top] = @intCast(m.scratch.items.len - scratch_top - 1);
                m.sortDecls(ast, @ptrCast(m.scratch.items[scratch_top + 1 ..]));
                m.decls.items(.type)[@intFromEnum(index)] = .container;
                m.decls.items(.data)[@intFromEnum(index)] = .{
                    .container = try m.encodeScratch(scratch_top),
                };

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

                const index = try m.appendDecl(.{
                    .type = undefined,
                    .file = file_index,
                    .node = node,
                    .data = undefined,
                });
                if (var_decl.ast.init_node == 0) return index;

                var buf: [2]Ast.Node.Index = undefined;
                if (ast.fullContainerDecl(&buf, var_decl.ast.init_node)) |container| {
                    const scratch_top = m.scratch.items.len;
                    defer m.scratch.shrinkRetainingCapacity(scratch_top);
                    try m.scratch.append(m.allocator, undefined); // length
                    for (container.ast.members) |member| {
                        const child_index = try m.processDecl(file_index, ast, member) orelse continue;
                        try m.scratch.append(m.allocator, @intFromEnum(child_index));
                    }
                    m.scratch.items[scratch_top] = @intCast(m.scratch.items.len - scratch_top - 1);
                    m.sortDecls(ast, @ptrCast(m.scratch.items[scratch_top + 1 ..]));
                    m.decls.items(.type)[@intFromEnum(index)] = .container;
                    m.decls.items(.data)[@intFromEnum(index)] = .{
                        .container = try m.encodeScratch(scratch_top),
                    };
                } else if (ast.nodes.items(.tag)[var_decl.ast.init_node] == .field_access) {
                    const ast_tags = ast.nodes.items(.tag);
                    const ast_datas = ast.nodes.items(.data);
                    const scratch_top = m.scratch.items.len;
                    defer m.scratch.shrinkRetainingCapacity(scratch_top);
                    try m.scratch.append(m.allocator, undefined); // length
                    try m.scratch.append(m.allocator, ast_datas[var_decl.ast.init_node].rhs);
                    var lhs = ast_datas[var_decl.ast.init_node].lhs;
                    while (ast_tags[lhs] == .field_access) : (lhs = ast_datas[lhs].lhs) {
                        try m.scratch.append(m.allocator, ast_datas[lhs].rhs);
                    }
                    m.scratch.items[scratch_top] = @intCast(m.scratch.items.len - scratch_top - 1);
                    mem.reverse(u32, m.scratch.items[scratch_top + 1 ..]);
                    if (ast_tags[lhs] == .identifier) {
                        m.decls.items(.type)[@intFromEnum(index)] = .alias;
                        m.decls.items(.data)[@intFromEnum(index)] = .{
                            .alias = try m.encodeScratch(scratch_top),
                        };
                    } else if (try m.importPath(m.files.items(.path)[@intFromEnum(file_index)], ast, lhs)) |import_path| {
                        defer m.allocator.free(import_path);
                        const import_decl = try m.appendDecl(.{
                            .type = .import,
                            .file = file_index,
                            .node = lhs,
                            .data = .{ .import = m.files_by_path.get(import_path).? },
                        });
                        try m.scratch.append(m.allocator, @intFromEnum(import_decl));
                        m.decls.items(.type)[@intFromEnum(index)] = .alias_import;
                        m.decls.items(.data)[@intFromEnum(index)] = .{
                            .alias_import = try m.encodeScratch(scratch_top),
                        };
                    } else {
                        m.decls.items(.type)[@intFromEnum(index)] = .other;
                        m.decls.items(.data)[@intFromEnum(index)] = .{ .none = {} };
                    }
                } else if (try m.importPath(m.files.items(.path)[@intFromEnum(file_index)], ast, var_decl.ast.init_node)) |import_path| {
                    defer m.allocator.free(import_path);
                    m.decls.items(.type)[@intFromEnum(index)] = .import;
                    m.decls.items(.data)[@intFromEnum(index)] = .{
                        .import = m.files_by_path.get(import_path).?,
                    };
                } else {
                    m.decls.items(.type)[@intFromEnum(index)] = .other;
                    m.decls.items(.data)[@intFromEnum(index)] = .{ .none = {} };
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

                return try m.appendDecl(.{
                    .type = .other,
                    .file = file_index,
                    .node = node,
                    .data = .{ .none = {} },
                });
            },
            else => return null,
        }
    }

    fn appendDecl(m: *Wip, decl: Decl) !Decl.Index {
        const index: Decl.Index = @enumFromInt(@as(u32, @intCast(m.decls.len)));
        try m.decls.append(m.allocator, decl);
        return index;
    }

    fn sortDecls(m: Wip, ast: Ast, decl_indexes: []Decl.Index) void {
        const Context = struct { ast: Ast, decls: Decl.List.Slice };
        mem.sort(Decl.Index, decl_indexes, Context{ .ast = ast, .decls = m.decls.slice() }, struct {
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

    fn encodeScratch(m: *Wip, scratch_top: usize) !ExtraIndex {
        const index: ExtraIndex = @enumFromInt(@as(u32, @intCast(m.extra.items.len)));
        try m.extra.appendSlice(m.allocator, m.scratch.items[scratch_top..]);
        return index;
    }
};
