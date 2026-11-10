// Builds abipak into zig-out/bin/abipak: a static binary, so it runs whatever the host's
// libraries are.
//
//     zig build                               for this machine
//     zig build -Dtarget=x86-linux            for another one (x86_64-linux, aarch64-linux)
//     zig build -Doptimize=ReleaseSmall       small, for shipping
//     zig build test                          the tests

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const abipak = b.addModule("abipak", .{
        .root_source_file = b.path("src/abipak.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "abipak",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "abipak", .module = abipak }},
        }),
    });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    run.addPassthruArgs();
    b.step("run", "Run abipak").dependOn(&run.step);

    const tests = b.addRunArtifact(b.addTest(.{ .root_module = abipak }));
    b.step("test", "Run the tests").dependOn(&tests.step);
}
