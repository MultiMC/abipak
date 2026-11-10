//! What an app needs from the host, as measure writes it and probe reads it:
//!
//!     {
//!       "format": 1,
//!       "arch": "x86_64",
//!       "interpreter": "/lib64/ld-linux-x86-64.so.2",
//!       "libs": [
//!         {"soname": "libQt5Core.so.5", "versions": ["Qt_5", "Qt_5.6"]},
//!         {"soname": "libz.so.1", "versions": []}
//!       ]
//!     }
//!
//! `libs` are the libraries the app's binaries link (DT_NEEDED) that the app doesn't bring
//! itself, each with every symbol version node the binaries need from it: exactly what the
//! dynamic loader checks, so no knowledge of how a library numbers its versions is needed
//! to check them. A library without symbol versions has an empty list; finding it is all
//! that can be checked.

const std = @import("std");

pub const format = 1;

pub const Lib = struct {
    soname: []const u8,
    versions: []const []const u8,
};

pub const Requirements = struct {
    format: u32 = format,
    /// x86, x86_64 or arm64
    arch: []const u8,
    /// the ELF interpreter the executables ask for; null when there are none
    interpreter: ?[]const u8,
    libs: []const Lib,
};

pub fn write(writer: *std.Io.Writer, requirements: Requirements) !void {
    try writer.print("{f}\n", .{std.json.fmt(requirements, .{ .whitespace = .indent_2 })});
}

/// Strict: a field it doesn't know is a requirement it can't check, so it refuses it
pub fn parse(arena: std.mem.Allocator, data: []const u8) !Requirements {
    const requirements = try std.json.parseFromSliceLeaky(Requirements, arena, data, .{});
    if (requirements.format != format) return error.UnsupportedFormat;
    return requirements;
}

/// A version node's name as a family and a number: "GLIBC_2.17" is GLIBC and 2.17,
/// "Qt_5" is Qt and 5. Names without a number at the end ("Qt_5_PRIVATE_API",
/// "GLIBC_PRIVATE") are a family of their own, with no number.
pub const Version = struct {
    family: []const u8,
    number: ?[]const u8,

    pub fn of(name: []const u8) Version {
        const underscore = std.mem.lastIndexOfScalar(u8, name, '_') orelse return .{ .family = name, .number = null };
        const number = name[underscore + 1 ..];
        if (number.len == 0 or !std.ascii.isDigit(number[0])) return .{ .family = name, .number = null };
        for (number) |c| if (c != '.' and !std.ascii.isDigit(c)) return .{ .family = name, .number = null };
        return .{ .family = name[0..underscore], .number = number };
    }
};

/// Dotted numbers compared part by part, numerically ("2.9" < "2.17")
pub fn compareNumbers(a: []const u8, b: []const u8) std.math.Order {
    var parts_a = std.mem.splitScalar(u8, a, '.');
    var parts_b = std.mem.splitScalar(u8, b, '.');
    while (true) {
        const part_a = parts_a.next();
        const part_b = parts_b.next();
        if (part_a == null and part_b == null) return .eq;
        const value_a = std.fmt.parseInt(u64, part_a orelse "0", 10) catch 0;
        const value_b = std.fmt.parseInt(u64, part_b orelse "0", 10) catch 0;
        const order = std.math.order(value_a, value_b);
        if (order != .eq) return order;
    }
}

/// By family, then by number: the order measure writes them in
pub fn versionLessThan(_: void, a: []const u8, b: []const u8) bool {
    const va = Version.of(a);
    const vb = Version.of(b);
    const families = std.mem.order(u8, va.family, vb.family);
    if (families != .eq) return families == .lt;
    if (va.number == null or vb.number == null) return std.mem.order(u8, a, b) == .lt;
    return compareNumbers(va.number.?, vb.number.?) == .lt;
}

/// The highest version node of each family in a list, for telling people what a library
/// has to be at least ("Qt_5.6", "GLIBC_2.14")
pub fn highest(arena: std.mem.Allocator, versions: []const []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (versions) |name| {
        const v = Version.of(name);
        var replaced = false;
        for (out.items) |*kept| {
            const k = Version.of(kept.*);
            if (!std.mem.eql(u8, k.family, v.family)) continue;
            replaced = true;
            if (v.number != null and k.number != null and compareNumbers(v.number.?, k.number.?) == .gt) kept.* = name;
        }
        if (!replaced) try out.append(arena, name);
    }
    return out.items;
}

test "version order" {
    var names = [_][]const u8{ "GLIBC_2.17", "Qt_5.6", "GLIBC_2.2.5", "Qt_5", "GLIBC_2.9", "GLIBC_PRIVATE" };
    std.mem.sort([]const u8, &names, {}, versionLessThan);
    const expected = [_][]const u8{ "GLIBC_2.2.5", "GLIBC_2.9", "GLIBC_2.17", "GLIBC_PRIVATE", "Qt_5", "Qt_5.6" };
    for (expected, names) |e, n| try std.testing.expectEqualStrings(e, n);
}

test "highest per family" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const out = try highest(arena_state.allocator(), &.{ "GLIBCXX_3.4.21", "CXXABI_1.3", "GLIBCXX_3.4.9", "CXXABI_1.3.9" });
    try std.testing.expectEqual(2, out.len);
    try std.testing.expectEqualStrings("GLIBCXX_3.4.21", out[0]);
    try std.testing.expectEqualStrings("CXXABI_1.3.9", out[1]);
}

test "round trip" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const original: Requirements = .{
        .arch = "x86_64",
        .interpreter = "/lib64/ld-linux-x86-64.so.2",
        .libs = &.{.{ .soname = "libQt5Core.so.5", .versions = &.{ "Qt_5", "Qt_5.6" } }},
    };
    var out: std.Io.Writer.Allocating = .init(arena);
    try write(&out.writer, original);
    const back = try parse(arena, out.written());
    try std.testing.expectEqualStrings("libQt5Core.so.5", back.libs[0].soname);
    try std.testing.expectEqualStrings("Qt_5.6", back.libs[0].versions[1]);
    try std.testing.expectError(error.UnknownField, parse(arena, "{\"format\": 1, \"arch\": \"x86_64\", \"interpreter\": null, \"libs\": [], \"gpu\": 1}"));
}
