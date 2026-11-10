//! probe: whether this host meets an app's requirements. Finds each library the way the
//! dynamic loader would, without loading anything: the loader's cache first, then the
//! usual library directories, taking the first file of that name that is an ELF file of
//! the app's architecture. Then checks that it defines every symbol version node the app
//! needs from it.
//!
//! Not followed (yet): DT_RUNPATH and DT_RPATH, LD_LIBRARY_PATH, and what the libraries
//! found need themselves (the distribution's packages take care of that).

const std = @import("std");
const elf = @import("elf.zig");
const ldcache = @import("ldcache.zig");
const requirements = @import("requirements.zig");
const measure = @import("measure.zig");

pub const LibResult = struct {
    soname: []const u8,
    /// the file the loader would take; null if there is none
    path: ?[]const u8,
    /// the version nodes needed that it doesn't define
    missing: []const []const u8,
    /// files of that name that aren't for the app's architecture, passed over
    passed_over: []const []const u8,
};

pub const Report = struct {
    arch: []const u8,
    /// null when the app asks for none
    interpreter: ?struct { path: []const u8, found: bool },
    libs: []const LibResult,

    pub fn met(report: Report) bool {
        if (report.interpreter) |i| if (!i.found) return false;
        for (report.libs) |lib| if (lib.path == null or lib.missing.len > 0) return false;
        return true;
    }
};

pub const Options = struct {
    /// the loader's cache; empty for none
    cache: []const u8 = ldcache.default_path,
    /// prefixed to every path looked at, to probe a system mounted somewhere else
    root: []const u8 = "",
};

/// The directories the loader looks in after its cache. glibc's own are /lib64 and
/// /usr/lib64 for 64-bit and /lib and /usr/lib for 32-bit; Debian and its derivatives add
/// their multiarch directories. All of them are tried; the architecture check decides.
fn defaultDirs(arch: []const u8) []const []const u8 {
    if (std.mem.eql(u8, arch, "x86_64")) return &.{ "/lib64", "/usr/lib64", "/lib/x86_64-linux-gnu", "/usr/lib/x86_64-linux-gnu", "/lib", "/usr/lib" };
    if (std.mem.eql(u8, arch, "x86")) return &.{ "/lib", "/usr/lib", "/lib/i386-linux-gnu", "/usr/lib/i386-linux-gnu", "/lib32", "/usr/lib32" };
    if (std.mem.eql(u8, arch, "arm64")) return &.{ "/lib64", "/usr/lib64", "/lib/aarch64-linux-gnu", "/usr/lib/aarch64-linux-gnu", "/lib", "/usr/lib" };
    return &.{};
}

pub fn probe(io: std.Io, arena: std.mem.Allocator, wanted: requirements.Requirements, options: Options) !Report {
    if (defaultDirs(wanted.arch).len == 0) return error.UnknownArch;
    var cache: []const ldcache.Entry = &.{};
    if (options.cache.len > 0) {
        const path = try std.mem.concat(arena, u8, &.{ options.root, options.cache });
        if (read(io, arena, path)) |data| {
            cache = ldcache.parse(arena, data) catch &.{};
        }
    }

    var libs = try arena.alloc(LibResult, wanted.libs.len);
    for (wanted.libs, 0..) |lib, i| {
        var candidates: std.ArrayList([]const u8) = .empty;
        for (cache) |entry| {
            if (std.mem.eql(u8, entry.name, lib.soname)) try candidates.append(arena, entry.path);
        }
        for (defaultDirs(wanted.arch)) |dir| {
            const path = try std.fs.path.join(arena, &.{ dir, lib.soname });
            // the cache usually lists the same files
            var listed = false;
            for (candidates.items) |c| listed = listed or std.mem.eql(u8, c, path);
            if (!listed) try candidates.append(arena, path);
        }

        var passed_over: std.ArrayList([]const u8) = .empty;
        var result: LibResult = .{ .soname = lib.soname, .path = null, .missing = &.{}, .passed_over = &.{} };
        for (candidates.items) |candidate| {
            const data = read(io, arena, try std.mem.concat(arena, u8, &.{ options.root, candidate })) orelse continue;
            const info = elf.parse(arena, data) catch {
                try passed_over.append(arena, candidate);
                continue;
            };
            const arch = elf.archName(info.class, info.machine) orelse "";
            if (!std.mem.eql(u8, arch, wanted.arch)) {
                try passed_over.append(arena, candidate);
                continue;
            }
            var missing: std.ArrayList([]const u8) = .empty;
            for (lib.versions) |version| {
                var defined = false;
                for (info.version_defs) |def| defined = defined or std.mem.eql(u8, def, version);
                if (!defined) try missing.append(arena, version);
            }
            result.path = candidate;
            result.missing = missing.items;
            break;
        }
        result.passed_over = passed_over.items;
        libs[i] = result;
    }

    var report: Report = .{ .arch = wanted.arch, .interpreter = null, .libs = libs };
    if (wanted.interpreter) |path| {
        var found = false;
        if (read(io, arena, try std.mem.concat(arena, u8, &.{ options.root, path }))) |data| {
            if (elf.parse(arena, data)) |info| {
                found = std.mem.eql(u8, elf.archName(info.class, info.machine) orelse "", wanted.arch);
            } else |_| {}
        }
        report.interpreter = .{ .path = path, .found = found };
    }
    return report;
}

/// A file's contents, or null if it can't be read (missing, a directory, no permission)
fn read(io: std.Io, arena: std.mem.Allocator, path: []const u8) ?[]u8 {
    return measure.readFile(io, arena, std.Io.Dir.cwd(), path) catch null;
}

/// For people: one line per library, then whether it's all met
pub fn describe(writer: *std.Io.Writer, arena: std.mem.Allocator, report: Report) !void {
    if (report.interpreter) |i| {
        try writer.print("{s:<8} interpreter {s}\n", .{ if (i.found) "ok" else "MISSING", i.path });
    }
    for (report.libs) |lib| {
        if (lib.path == null) {
            try writer.print("MISSING  {s}\n", .{lib.soname});
        } else if (lib.missing.len > 0) {
            const short = try requirements.highest(arena, lib.missing);
            try writer.print("TOO OLD  {s}: {s} lacks {s}\n", .{ lib.soname, lib.path.?, try std.mem.join(arena, ", ", short) });
        } else {
            try writer.print("ok       {s}: {s}\n", .{ lib.soname, lib.path.? });
        }
        for (lib.passed_over) |path| try writer.print("         passed over {s} (another architecture or not ELF)\n", .{path});
    }
    try writer.print("{s}\n", .{if (report.met()) "met: this system has everything the app needs" else "NOT MET"});
}
