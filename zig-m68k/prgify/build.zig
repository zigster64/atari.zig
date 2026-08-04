const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.graph.host;
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "prgify",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const copy = b.addSystemCommand(&.{ "sh", "-c" });
    copy.addArg("cp \"$0\" ~/Atari/bin/prgify");
    copy.addFileArg(exe.getEmittedBin());
    copy.step.dependOn(&exe.step);
    b.getInstallStep().dependOn(&copy.step);

    const run_step = b.step("run", "Run prgify");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    if (b.args) |args| run_cmd.addArgs(args);
}
