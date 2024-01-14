const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const Ast = std.zig.Ast;
const assert = std.debug.assert;

files: File.List.Slice,
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

pub const ExtraIndex = enum(u32) { none = std.math.maxInt(u32), _ };

pub const File = struct {
    status: Status,
    path: []u8,
    source: [:0]u8,
    ast: Ast,
    root_decl: Decl.Index,
    imports: std.AutoHashMapUnmanaged(Ast.Node.Index, File),

    pub const Index = enum(u32) { root = 0, _ };
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
    node: Ast.Node.Index,
    /// If the decl is a container, this will be a length `n` followed by `n`
    /// `Decl.Index`es for the children.
    children: ExtraIndex,

    pub const Index = enum(u32) { root = 0, _ };
    pub const List = std.MultiArrayList(Decl);

    pub const Type = enum {
        value,
        namespace,
        container,
        function,
    };
};

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

pub fn declChildren(mod: Module, decl: Decl.Index) []const Decl.Index {
    const children = mod.decls.items(.children)[@intFromEnum(decl)];
    if (children == .none) return &.{};
    const len = mod.extra[@intFromEnum(children)];
    return @ptrCast(mod.extra[@intFromEnum(children) + 1 ..][0..len]);
}

const Wip = struct {
    files: File.List = .{},
    files_by_path: std.StringHashMapUnmanaged(File.Index) = .{},
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

        // The root file must have index 0.
        const root_file_index = mod.files_by_path.get(root_path) orelse return error.InvalidRootPath;
        if (root_file_index != .root) {
            const old_root_file = mod.files.get(0);
            mod.files.set(0, mod.files.get(@intFromEnum(root_file_index)));
            mod.files.set(@intFromEnum(root_file_index), old_root_file);
            mod.files_by_path.getEntry(root_path).?.value_ptr.* = .root;
            mod.files_by_path.getEntry(old_root_file.path).?.value_ptr.* = root_file_index;
        }
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
        _ = try mod.processNode(file, 0);

        status.* = .parsed;
    }

    fn processNode(mod: *Wip, file: File.Index, node: Ast.Node.Index) !?Decl.Index {
        const ast = mod.files.items(.ast)[@intFromEnum(file)];
        switch (ast.nodes.items(.tag)[node]) {
            .root => {
                assert(node == 0);
                const index = try mod.appendDecl(.{
                    .file = file,
                    .node = node,
                    .children = undefined,
                });
                mod.files.items(.root_decl)[@intFromEnum(file)] = index;

                const scratch_top = mod.scratch.items.len;
                defer mod.scratch.shrinkRetainingCapacity(scratch_top);
                try mod.scratch.append(mod.allocator, undefined); // length
                for (ast.rootDecls()) |child| {
                    const decl_index = try mod.processNode(file, child) orelse continue;
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
                    .node = node,
                    .children = undefined,
                });
                if (var_decl.ast.init_node == 0) return index;

                var buf: [2]Ast.Node.Index = undefined;
                if (ast.fullContainerDecl(&buf, var_decl.ast.init_node)) |container| {
                    const scratch_top = mod.scratch.items.len;
                    defer mod.scratch.shrinkRetainingCapacity(scratch_top);
                    try mod.scratch.append(mod.allocator, undefined); // length
                    for (container.ast.members) |member| {
                        const child_index = try mod.processNode(file, member) orelse continue;
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

    fn encodeScratch(mod: *Wip, scratch_top: usize) !ExtraIndex {
        const index: ExtraIndex = @enumFromInt(@as(u32, @intCast(mod.extra.items.len)));
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
