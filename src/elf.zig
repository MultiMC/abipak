//! What the dynamic loader reads from an ELF file: its class and machine, the interpreter,
//! and from the dynamic section the libraries it needs (DT_NEEDED), its own name
//! (DT_SONAME), the symbol versions it needs from each library (DT_VERNEED) and the ones
//! it defines (DT_VERDEF). Everything is found through the program headers, as the loader
//! finds it, so files without section headers read the same.

const std = @import("std");

pub const Class = enum { elf32, elf64 };

/// The symbol versions a file needs from one library (one Verneed entry)
pub const VersionNeed = struct {
    file: []const u8,
    /// required: the loader refuses to load the file if the library doesn't define them
    names: []const []const u8,
    /// weak (VER_FLG_WEAK): the loader only warns
    weak: []const []const u8,
};

pub const Info = struct {
    class: Class,
    machine: u16,
    /// PT_INTERP: the dynamic loader an executable asks for
    interpreter: ?[]const u8 = null,
    soname: ?[]const u8 = null,
    needed: []const []const u8 = &.{},
    version_needs: []const VersionNeed = &.{},
    /// the version names it defines, without the base definition (its own name)
    version_defs: []const []const u8 = &.{},
};

pub const Error = error{ NotElf, Malformed, Unsupported } || std.mem.Allocator.Error;

pub const EM_386 = 3;
pub const EM_X86_64 = 62;
pub const EM_AARCH64 = 183;

const PT_LOAD = 1;
const PT_DYNAMIC = 2;
const PT_INTERP = 3;

const DT_NULL = 0;
const DT_NEEDED = 1;
const DT_STRTAB = 5;
const DT_STRSZ = 10;
const DT_SONAME = 14;
const DT_VERDEF = 0x6ffffffc;
const DT_VERDEFNUM = 0x6ffffffd;
const DT_VERNEED = 0x6ffffffe;
const DT_VERNEEDNUM = 0x6fffffff;

const VER_FLG_BASE = 1;
const VER_FLG_WEAK = 2;

pub fn isElf(data: []const u8) bool {
    return data.len >= 4 and std.mem.eql(u8, data[0..4], "\x7fELF");
}

/// Reads integers at file offsets, refusing anything outside the file
const Reader = struct {
    data: []const u8,
    endian: std.builtin.Endian,
    class: Class,

    fn int(r: Reader, comptime T: type, offset: u64) Error!T {
        const size = @sizeOf(T);
        if (offset > r.data.len or r.data.len - offset < size) return error.Malformed;
        const at: usize = @intCast(offset);
        return std.mem.readInt(T, r.data[at..][0..size], r.endian);
    }

    /// An address-sized field: 4 bytes in ELF32, 8 in ELF64
    fn word(r: Reader, offset: u64) Error!u64 {
        return switch (r.class) {
            .elf32 => try r.int(u32, offset),
            .elf64 => try r.int(u64, offset),
        };
    }

    fn string(r: Reader, offset: u64, end: u64) Error![]const u8 {
        if (offset >= end or end > r.data.len) return error.Malformed;
        const bytes = r.data[@intCast(offset)..@intCast(end)];
        const len = std.mem.indexOfScalar(u8, bytes, 0) orelse return error.Malformed;
        return bytes[0..len];
    }
};

const Load = struct { vaddr: u64, offset: u64, filesz: u64 };

/// A count of entries from the file. Each entry takes at least a byte, so more than the
/// file's size is malformed; that also makes it fit a usize on 32-bit hosts.
fn entryCount(n: u64, data: []const u8) Error!usize {
    if (n > data.len) return error.Malformed;
    return @intCast(n);
}

/// The file offset of a virtual address, through the PT_LOAD segments
fn fileOffset(loads: []const Load, vaddr: u64) Error!u64 {
    for (loads) |load| {
        if (vaddr >= load.vaddr and vaddr - load.vaddr < load.filesz) return load.offset + (vaddr - load.vaddr);
    }
    return error.Malformed;
}

pub fn parse(arena: std.mem.Allocator, data: []const u8) Error!Info {
    if (!isElf(data)) return error.NotElf;
    if (data.len < 64) return error.Malformed;
    const class: Class = switch (data[4]) {
        1 => .elf32,
        2 => .elf64,
        else => return error.Unsupported,
    };
    const endian: std.builtin.Endian = switch (data[5]) {
        1 => .little,
        2 => .big,
        else => return error.Unsupported,
    };
    const r: Reader = .{ .data = data, .endian = endian, .class = class };
    var info: Info = .{ .class = class, .machine = try r.int(u16, 18) };

    const phoff = try r.word(if (class == .elf64) 32 else 28);
    const phentsize = try r.int(u16, if (class == .elf64) 54 else 42);
    const phnum = try r.int(u16, if (class == .elf64) 56 else 44);

    var loads: std.ArrayList(Load) = .empty;
    var dynamic: ?struct { offset: u64, size: u64 } = null;
    for (0..phnum) |i| {
        const ph = phoff + i * phentsize;
        const p_type = try r.int(u32, ph);
        // ELF64: type, flags, offset, vaddr, paddr, filesz; ELF32: type, offset, vaddr, paddr, filesz
        const offset = try r.word(if (class == .elf64) ph + 8 else ph + 4);
        const vaddr = try r.word(if (class == .elf64) ph + 16 else ph + 8);
        const filesz = try r.word(if (class == .elf64) ph + 32 else ph + 16);
        switch (p_type) {
            PT_LOAD => try loads.append(arena, .{ .vaddr = vaddr, .offset = offset, .filesz = filesz }),
            PT_DYNAMIC => dynamic = .{ .offset = offset, .size = filesz },
            PT_INTERP => info.interpreter = try r.string(offset, offset + filesz),
            else => {},
        }
    }
    const dyn = dynamic orelse return info;

    // The dynamic section: tag and value pairs, until DT_NULL
    var strtab: ?u64 = null;
    var strsz: u64 = 0;
    var soname: ?u64 = null;
    var needed: std.ArrayList(u64) = .empty;
    var verneed: ?u64 = null;
    var verneednum: u64 = 0;
    var verdef: ?u64 = null;
    var verdefnum: u64 = 0;
    const entry_size: u64 = if (class == .elf64) 16 else 8;
    var at = dyn.offset;
    while (at + entry_size <= dyn.offset + dyn.size) : (at += entry_size) {
        const tag = try r.word(at);
        const value = try r.word(at + entry_size / 2);
        switch (tag) {
            DT_NULL => break,
            DT_NEEDED => try needed.append(arena, value),
            DT_STRTAB => strtab = value,
            DT_STRSZ => strsz = value,
            DT_SONAME => soname = value,
            DT_VERNEED => verneed = value,
            DT_VERNEEDNUM => verneednum = value,
            DT_VERDEF => verdef = value,
            DT_VERDEFNUM => verdefnum = value,
            else => {},
        }
    }
    const strings = try fileOffset(loads.items, strtab orelse return error.Malformed);
    const strings_end = strings + strsz;

    if (soname) |offset| info.soname = try r.string(strings + offset, strings_end);
    const names = try arena.alloc([]const u8, needed.items.len);
    for (needed.items, 0..) |offset, i| names[i] = try r.string(strings + offset, strings_end);
    info.needed = names;

    // Verneed entries: version, count, file, aux, next; each with Vernaux: hash, flags,
    // other, name, next. The same layout in ELF32 and ELF64.
    if (verneed) |vaddr| {
        var needs: std.ArrayList(VersionNeed) = .empty;
        var offset = try fileOffset(loads.items, vaddr);
        for (0..try entryCount(verneednum, data)) |_| {
            const count = try r.int(u16, offset + 2);
            var required: std.ArrayList([]const u8) = .empty;
            var weak: std.ArrayList([]const u8) = .empty;
            var aux = offset + try r.int(u32, offset + 8);
            for (0..count) |_| {
                const name = try r.string(strings + try r.int(u32, aux + 8), strings_end);
                if (try r.int(u16, aux + 4) & VER_FLG_WEAK != 0) {
                    try weak.append(arena, name);
                } else {
                    try required.append(arena, name);
                }
                const next = try r.int(u32, aux + 12);
                if (next == 0) break;
                aux += next;
            }
            try needs.append(arena, .{
                .file = try r.string(strings + try r.int(u32, offset + 4), strings_end),
                .names = required.items,
                .weak = weak.items,
            });
            const next = try r.int(u32, offset + 12);
            if (next == 0) break;
            offset += next;
        }
        info.version_needs = needs.items;
    }

    // Verdef entries: version, flags, index, count, hash, aux, next; the first Verdaux
    // (name, next) names the version, the others its parents
    if (verdef) |vaddr| {
        var defs: std.ArrayList([]const u8) = .empty;
        var offset = try fileOffset(loads.items, vaddr);
        for (0..try entryCount(verdefnum, data)) |_| {
            const flags = try r.int(u16, offset + 2);
            if (flags & VER_FLG_BASE == 0) {
                const aux = offset + try r.int(u32, offset + 12);
                try defs.append(arena, try r.string(strings + try r.int(u32, aux), strings_end));
            }
            const next = try r.int(u32, offset + 16);
            if (next == 0) break;
            offset += next;
        }
        info.version_defs = defs.items;
    }
    return info;
}

/// The architecture name used in requirements, for a class and machine; null if abipak
/// doesn't know it
pub fn archName(class: Class, machine: u16) ?[]const u8 {
    return switch (machine) {
        EM_386 => if (class == .elf32) "x86" else null,
        EM_X86_64 => if (class == .elf64) "x86_64" else null,
        EM_AARCH64 => if (class == .elf64) "arm64" else null,
        else => null,
    };
}

test "a library of this system" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;
    // glibc's libc defines its versions and names itself; skipped where it isn't there
    const data = std.Io.Dir.cwd().readFileAlloc(io, "/usr/lib/libc.so.6", arena, .limited(64 << 20)) catch return error.SkipZigTest;
    const info = try parse(arena, data);
    try std.testing.expectEqualStrings("libc.so.6", info.soname.?);
    var found = false;
    for (info.version_defs) |name| found = found or std.mem.eql(u8, name, "GLIBC_2.17");
    try std.testing.expect(found);
}

test "not an ELF file" {
    const script: [80]u8 = @splat('x');
    try std.testing.expectError(error.NotElf, parse(std.testing.allocator, &script));
}
