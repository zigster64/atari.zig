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

    const obj = b.addObject(.{
        .name = "HELLO",
        .root_module = mod,
    });
    obj.entry = .{ .symbol_name = "_start" };
    obj.bundle_compiler_rt = false;

    const startup = b.addSystemCommand(&.{ "m68k-elf-as", "-o" });
    const startup_o = startup.addOutputFileArg("startup.o");
    startup.addFileArg(b.path("src/startup.s"));

    // Link .o → relocatable ELF
    const elf = b.addSystemCommand(&.{ "m68k-elf-ld", "--relocatable", "--gc-sections", "--script" });
    elf.addFileArg(b.path("prg.ld"));
    elf.addArg("-o");
    const elf_out = elf.addOutputFileArg("HELLO.elf");
    elf.addFileArg(startup_o);
    elf.addFileArg(obj.getEmittedBin());
    elf.step.dependOn(&startup.step);

    // ELF → PRG via toslink + copy to CDrive
    const finish = b.addSystemCommand(&.{ "sh", "-c" });
    // finish.addArg("$HOME/Atari/bin/toslink -s -o /tmp/HELLO.PRG \"$0\" && mkdir -p ~/Atari/CDrive && cp /tmp/HELLO.PRG ~/Atari/CDrive/HELLO.PRG");
    finish.addArg("mkdir -p ~/Atari/CDrive && $HOME/Atari/bin/toslink -s -o ~/Atari/CDrive/HELLO.PRG \"$0\"");
    finish.addFileArg(elf_out);
    finish.step.dependOn(&elf.step);

    b.getInstallStep().dependOn(&finish.step);
}
