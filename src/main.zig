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

var modules = std.ArrayList(Module).init(allocator);
const ModuleIndex = enum(u32) { _ };

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

/// Returns a negative error code corresponding to `err`.
fn codeFromError(err: anyerror) i32 {
    return -@as(i32, @intFromError(err)) - 1;
}
