//! measure: what an app's ELF files need from the host. Reads every regular file in the
//! app's directory; for the ELF files among them, the libraries they link and the symbol
//! version nodes they need from each. Libraries the app brings itself (a file of that name
//! in the directory, or a file whose DT_SONAME it is) aren't requirements.

const std = @import("std");
const elf = @import("elf.zig");
const requirements = @import("requirements.zig");

pub const Measured = struct {
    requirements: requirements.Requirements,
    /// what can't be stated as a requirement, for the person measuring (private API,
    /// weak version references, files abipak can't read)
    warnings: []const []const u8,
};

pub fn measure(io: std.Io, arena: std.mem.Allocator, root: []const u8) !Measured {
    var dir = try std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(arena);
    defer walker.deinit();

    var warnings: std.ArrayList([]const u8) = .empty;
    // what the app brings: file and link names, and the sonames of its libraries
    var own: std.StringHashMapUnmanaged(void) = .empty;
    // soname: the version nodes needed from it
    var needed: std.StringArrayHashMapUnmanaged(std.StringArrayHashMapUnmanaged(void)) = .empty;
    var arch: ?[]const u8 = null;
    var interpreter: ?[]const u8 = null;

    while (try walker.next(io)) |entry| {
        if (entry.kind == .sym_link) try own.put(arena, try arena.dupe(u8, entry.basename), {});
        if (entry.kind != .file) continue;
        const path = try arena.dupe(u8, entry.path);
        try own.put(arena, try arena.dupe(u8, entry.basename), {});
        const data = try readFile(io, arena, entry.dir, entry.basename);
        if (!elf.isElf(data)) continue;
        const info = elf.parse(arena, data) catch |err| {
            try warnings.append(arena, try std.fmt.allocPrint(arena, "{s}: can't read it as ELF ({t})", .{ path, err }));
            continue;
        };
        const this_arch = elf.archName(info.class, info.machine) orelse
            return fail(arena, "{s}: an architecture abipak doesn't know (machine {d})", .{ path, info.machine });
        if (arch) |a| {
            if (!std.mem.eql(u8, a, this_arch)) return fail(arena, "{s} is {s}, other files are {s}", .{ path, this_arch, a });
        }
        arch = this_arch;
        if (info.interpreter) |i| {
            if (interpreter) |other| {
                if (!std.mem.eql(u8, other, i)) return fail(arena, "{s} asks for the interpreter {s}, others for {s}", .{ path, i, other });
            }
            interpreter = i;
        }
        if (info.soname) |soname| try own.put(arena, soname, {});
        for (info.needed) |soname| {
            const gop = try needed.getOrPut(arena, soname);
            if (!gop.found_existing) gop.value_ptr.* = .empty;
        }
        for (info.version_needs) |need| {
            const gop = try needed.getOrPut(arena, need.file);
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            for (need.names) |name| {
                try gop.value_ptr.put(arena, name, {});
                if (std.mem.endsWith(u8, name, "_PRIVATE_API")) {
                    try warnings.append(arena, try std.fmt.allocPrint(arena, "{s} uses {s}'s private API ({s}): it needs exactly the version it was built with, which version nodes don't express", .{ path, need.file, name }));
                }
            }
            for (need.weak) |name| {
                try warnings.append(arena, try std.fmt.allocPrint(arena, "{s}: a weak reference to {s} in {s}, not a requirement", .{ path, name, need.file }));
            }
        }
    }

    var libs: std.ArrayList(requirements.Lib) = .empty;
    for (needed.keys(), needed.values()) |soname, versions| {
        if (own.contains(soname)) continue;
        const names = try arena.dupe([]const u8, versions.keys());
        std.mem.sort([]const u8, names, {}, requirements.versionLessThan);
        try libs.append(arena, .{ .soname = soname, .versions = names });
    }
    std.mem.sort(requirements.Lib, libs.items, {}, struct {
        fn lessThan(_: void, a: requirements.Lib, b: requirements.Lib) bool {
            return std.mem.order(u8, a.soname, b.soname) == .lt;
        }
    }.lessThan);
    return .{
        .requirements = .{
            .arch = arch orelse return fail(arena, "no ELF files in {s}", .{root}),
            .interpreter = interpreter,
            .libs = libs.items,
        },
        .warnings = warnings.items,
    };
}

pub var failure: []const u8 = "";

fn fail(arena: std.mem.Allocator, comptime format: []const u8, args: anytype) error{ Measure, OutOfMemory } {
    failure = try std.fmt.allocPrint(arena, format, args);
    return error.Measure;
}

/// A whole file, read to its end
pub fn readFile(io: std.Io, arena: std.mem.Allocator, dir: std.Io.Dir, path: []const u8) ![]u8 {
    const file = try dir.openFile(io, path, .{});
    defer file.close(io);
    var buffer: [64 * 1024]u8 = undefined;
    var reader = file.readerStreaming(io, &buffer);
    return reader.interface.allocRemaining(arena, .limited(1 << 30)) catch |err| switch (err) {
        error.ReadFailed => return reader.err.?,
        else => return err,
    };
}
