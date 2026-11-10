//! The abipak command:
//!
//!     abipak measure <directory>                 the requirements of an app's ELF files,
//!                                                as JSON on standard output
//!     abipak probe [--root DIR] <requirements>   whether this system meets them; exit
//!                                                status 0 if it does, 1 if not
//!
//! measure's warnings go to standard error. probe's --root looks at a system mounted at
//! DIR instead of this one. A requirements file of "-" is standard input.

const std = @import("std");
const abipak = @import("abipak");

const usage =
    \\usage: abipak measure <directory>
    \\       abipak probe [--root DIR] <requirements.json | ->
    \\
;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 2) fail("{s}", .{usage});

    var buffer: [4096]u8 = undefined;
    var stdout: std.Io.File.Writer = .init(.stdout(), io, &buffer);
    const out = &stdout.interface;

    const command = args[1];
    if (std.mem.eql(u8, command, "measure")) {
        if (args.len != 3) fail("{s}", .{usage});
        const measured = abipak.measure.measure(io, arena, args[2]) catch |err| switch (err) {
            error.Measure => fail("measure: {s}", .{abipak.measure.failure}),
            else => fail("measure: {s}: {t}", .{ args[2], err }),
        };
        for (measured.warnings) |warning| std.debug.print("warning: {s}\n", .{warning});
        try abipak.requirements.write(out, measured.requirements);
        try out.flush();
    } else if (std.mem.eql(u8, command, "probe")) {
        var options: abipak.probe.Options = .{};
        var file: ?[]const u8 = null;
        var i: usize = 2;
        while (i < args.len) : (i += 1) {
            if (std.mem.eql(u8, args[i], "--root")) {
                i += 1;
                if (i == args.len) fail("--root needs a directory\n{s}", .{usage});
                options.root = std.mem.trimEnd(u8, args[i], "/");
            } else if (file == null) {
                file = args[i];
            } else {
                fail("{s}", .{usage});
            }
        }
        const path = file orelse fail("{s}", .{usage});
        const data = if (std.mem.eql(u8, path, "-"))
            try readStdin(io, arena)
        else
            abipak.measure.readFile(io, arena, std.Io.Dir.cwd(), path) catch |err| fail("probe: {s}: {t}", .{ path, err });
        const wanted = abipak.requirements.parse(arena, data) catch |err| fail("probe: {s} isn't a requirements file: {t}", .{ path, err });
        const report = abipak.probe.probe(io, arena, wanted, options) catch |err| fail("probe: {t}", .{err});
        try abipak.probe.describe(out, arena, report);
        try out.flush();
        if (!report.met()) std.process.exit(1);
    } else if (std.mem.eql(u8, command, "-h") or std.mem.eql(u8, command, "--help")) {
        std.debug.print("{s}", .{usage});
    } else {
        fail("unknown command {s}\n{s}", .{ command, usage });
    }
}

fn readStdin(io: std.Io, arena: std.mem.Allocator) ![]u8 {
    var buffer: [4096]u8 = undefined;
    var reader = std.Io.File.stdin().readerStreaming(io, &buffer);
    return reader.interface.allocRemaining(arena, .limited(64 << 20));
}

fn fail(comptime format: []const u8, args: anytype) noreturn {
    std.debug.print(format ++ "\n", args);
    std.process.exit(2);
}
