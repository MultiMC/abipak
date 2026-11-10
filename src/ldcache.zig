//! The dynamic loader's cache, /etc/ld.so.cache (written by ldconfig): which files the
//! library names map to. Only the format glibc has written since 2.32,
//! "glibc-ld.so.cache1.1", is read; an older file that starts with the old format has the
//! new one after it, and that part is used. The cache is in the machine's own byte order.

const std = @import("std");

pub const default_path = "/etc/ld.so.cache";

pub const Entry = struct {
    /// the library name it's looked up by (a soname)
    name: []const u8,
    path: []const u8,
};

const magic = "glibc-ld.so.cache1.1";
// magic and version (20), nlibs, len_strings, flags and padding, extension_offset, unused[3]
const header_size = 48;
// flags, key, value, osversion (4 each), hwcap (8)
const entry_size = 24;

pub const Error = error{Malformed} || std.mem.Allocator.Error;

/// The entries in the cache's order (the loader takes the first that fits). String offsets
/// are relative to the start of the new format's header.
pub fn parse(arena: std.mem.Allocator, data: []const u8) Error![]Entry {
    const start = std.mem.indexOf(u8, data, magic) orelse return error.Malformed;
    const cache = data[start..];
    if (cache.len < header_size) return error.Malformed;
    const count = std.mem.readInt(u32, cache[20..24], .native);
    if (count > (cache.len - header_size) / entry_size) return error.Malformed;
    const entries = try arena.alloc(Entry, count);
    for (entries, 0..) |*entry, i| {
        const at = header_size + i * entry_size;
        entry.* = .{
            .name = try string(cache, std.mem.readInt(u32, cache[at + 4 ..][0..4], .native)),
            .path = try string(cache, std.mem.readInt(u32, cache[at + 8 ..][0..4], .native)),
        };
    }
    return entries;
}

fn string(cache: []const u8, offset: u32) Error![]const u8 {
    if (offset >= cache.len) return error.Malformed;
    const len = std.mem.indexOfScalar(u8, cache[offset..], 0) orelse return error.Malformed;
    return cache[offset..][0..len];
}

test "a cache with two entries" {
    const strings = "libfoo.so.1\x00/usr/lib/libfoo.so.1\x00";
    var data: [header_size + 2 * entry_size + strings.len]u8 = @splat(0);
    @memcpy(data[0..magic.len], magic);
    std.mem.writeInt(u32, data[20..24], 2, .native);
    const strings_at = header_size + 2 * entry_size;
    @memcpy(data[strings_at..], strings);
    for (0..2) |i| {
        const at = header_size + i * entry_size;
        std.mem.writeInt(u32, data[at + 4 ..][0..4], strings_at, .native);
        std.mem.writeInt(u32, data[at + 8 ..][0..4], strings_at + 12, .native);
    }
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const entries = try parse(arena_state.allocator(), &data);
    try std.testing.expectEqual(2, entries.len);
    try std.testing.expectEqualStrings("libfoo.so.1", entries[1].name);
    try std.testing.expectEqualStrings("/usr/lib/libfoo.so.1", entries[1].path);
}

test "not a cache" {
    var data: [80]u8 = @splat(0);
    @memcpy(data[0..11], "ld.so-1.7.0");
    try std.testing.expectError(error.Malformed, parse(std.testing.allocator, &data));
}
