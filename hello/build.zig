const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.resolveTargetQuery(.{
        .cpu_arch = .m68k,
        .os_tag = .freestanding,
        .abi = .none,
    });

    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = .ReleaseSmall,
    });

    const exe = b.addExecutable(.{
        .name = "HELLO",
        .root_module = mod,
    });

    exe.entry = .{ .symbol_name = "_start" };
    exe.bundle_compiler_rt = false;

    const install_step = b.addInstallArtifact(exe, .{});

    // Attach 28-byte Atari ST GEMDOS header
    const prg_step = b.addSystemCommand(&.{
        "sh",
        "-c",
        \\OBJ=$(b.getInstallPath(.bin, "HELLO"));
        \\HEADER="\x60\x1A\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00";
        \\printf "$HEADER" | cat - "$OBJ" > ~/Atari/CDrive/HELLO.PRG
    });

    prg_step.step.dependOn(&install_step.step);
    b.getInstallStep().dependOn(&prg_step.step);
}
