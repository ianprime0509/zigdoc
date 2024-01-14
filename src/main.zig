const std = @import("std");
const Module = @import("Module.zig");
const assert = std.debug.assert;

comptime {
    if (@import("builtin").cpu.arch != .wasm32) {
        @compileError("This program only works on Wasm32");
    }
}

pub const os = struct {
    pub const PATH_MAX = 4096;
};

const allocator = std.heap.wasm_allocator;

/// Memory usable by the client (e.g. as scratch space to pass arguments).
///
/// The list is given an alignment of 2 so that its memory address can be
/// unambiguously represented in a `u31` (by dividing it by 2), allowing it to
/// be returned in the positive range of an `i32`.
var client_memory = std.ArrayListAligned(u8, 2).init(allocator);

/// An arena for storing dynamically allocated return values. The memory stored
/// here is only valid until the next call to any exported function.
var return_arena = std.heap.ArenaAllocator.init(allocator);

var modules = std.ArrayList(Module).init(allocator);
const ModuleIndex = enum(u32) { _ };

/// A placeholder value used to indicate a missing index, when the return value
/// of a function indicates an index.
const missing_index = std.math.maxInt(i32);

/// Ensures that the client memory is at least `new_size`.
///
/// On success, returns the address of the new client memory divided by 2.
export fn ensureTotalClientMemoryCapacity(new_size: usize) i32 {
    client_memory.ensureTotalCapacity(new_size) catch |err| return codeFromError(err);
    return @intCast(@intFromPtr(client_memory.items.ptr) / 2);
}

export fn addModule(
    root_path_ptr: [*]const u8,
    root_path_len: usize,
    source_tar_gz_ptr: [*]const u8,
    source_tar_gz_len: usize,
) i32 {
    const root_path = root_path_ptr[0..root_path_len];
    const source_tar_gz = source_tar_gz_ptr[0..source_tar_gz_len];
    const index = addModuleImpl(root_path, source_tar_gz) catch |err| return codeFromError(err);
    return @intCast(@intFromEnum(index));
}

fn addModuleImpl(root_path: []const u8, source_tar_gz: []const u8) !ModuleIndex {
    const index: ModuleIndex = @enumFromInt(modules.items.len);
    var source_tar_gz_stream = std.io.fixedBufferStream(source_tar_gz);
    var mod = try Module.readFromTarGz(allocator, root_path, source_tar_gz_stream.reader());
    errdefer mod.deinit(allocator);
    try modules.append(mod);
    return index;
}

export fn rootFile(mod: ModuleIndex) i32 {
    return @intCast(@intFromEnum(modules.items[@intFromEnum(mod)].root_file));
}

export fn rootDecl(mod: ModuleIndex, file: Module.File.Index) i32 {
    const m = modules.items[@intFromEnum(mod)];
    return @intCast(@intFromEnum(m.files.items(.root_decl)[@intFromEnum(file)]));
}

export fn fileSource(
    mod: ModuleIndex,
    file: Module.File.Index,
    source_ptr_out: *[*]const u8,
    source_len_out: *usize,
) i32 {
    const m = modules.items[@intFromEnum(mod)];
    const status = m.files.items(.status)[@intFromEnum(file)];
    if (status == .invalid) return codeFromError(error.InvalidFile);
    const source = m.files.items(.source)[@intFromEnum(file)];
    source_ptr_out.* = source.ptr;
    source_len_out.* = source.len;
    return 0;
}

export fn declChildren(
    mod: ModuleIndex,
    decl: Module.Decl.Index,
    json_ptr_out: *[*]const u8,
    json_len_out: *usize,
) i32 {
    const json = declChildrenImpl(mod, decl) catch |err| return codeFromError(err);
    json_ptr_out.* = json.ptr;
    json_len_out.* = json.len;
    return 0;
}

fn declChildrenImpl(mod: ModuleIndex, decl: Module.Decl.Index) ![]const u8 {
    _ = return_arena.reset(.retain_capacity);
    const m = modules.items[@intFromEnum(mod)];
    var json = std.ArrayList(u8).init(return_arena.allocator());
    defer json.deinit();

    var json_writer = std.json.writeStream(json.writer(), .{});
    try json_writer.beginArray();
    for (m.declChildren(decl)) |child| {
        if (!m.declPublic(child)) continue;
        try json_writer.beginObject();
        try json_writer.objectField("index");
        try json_writer.write(@intFromEnum(child));
        try json_writer.objectField("type");
        try json_writer.write(m.declType(child));
        try json_writer.objectField("name");
        try json_writer.write(m.declName(child));
        try json_writer.endObject();
    }
    try json_writer.endArray();

    return try json.toOwnedSlice();
}

export fn declChild(
    mod: ModuleIndex,
    decl: Module.Decl.Index,
    child_ptr: [*]const u8,
    child_len: usize,
) i32 {
    const child = child_ptr[0..child_len];
    const index = modules.items[@intFromEnum(mod)].declChild(decl, child) orelse return missing_index;
    return @intCast(@intFromEnum(index));
}

/// Returns a negative error code corresponding to `err`.
fn codeFromError(err: anyerror) i32 {
    return -@as(i32, @intFromError(err)) - 1;
}
