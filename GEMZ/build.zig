const std = @import("std");

// GEMZ build: produces HELLO.PRG from src/hello.zig, which imports the
// "gemz" module (src/root.zig) as its GEM wrapper library.
//
// Pipeline (mirrors ../hello):
//   zig build-obj (hello.zig + gemz)  ->  HELLO.o
//   m68k-elf-as src/startup.s          ->  startup.o   (trampoline at text 0)
//   m68k-elf-ld --relocatable          ->  HELLO.elf   (via prg.ld)
//   toslink -s                         ->  zig-out/atari/HELLO.PRG

pub fn build(b: *std.Build) void {
    // GEMZ library module. Target is inherited from the importing module
    // (the hello module below sets m68k-freestanding).
    const gemz = b.addModule("gemz", .{
        .root_source_file = b.path("src/root.zig"),
    });

    // m68k freestanding target (Atari ST / GEMDOS).
    const target = b.resolveTargetQuery(.{
        .cpu_arch = .m68k,
        .os_tag = .freestanding,
        .abi = .none,
    });

    // The hello program, importing the gemz module.
    const hello = b.createModule(.{
        .root_source_file = b.path("src/hello.zig"),
        .target = target,
        .optimize = .ReleaseSmall,
        .imports = &.{
            .{ .name = "gemz", .module = gemz },
        },
    });

    // Stage 1: Zig -> relocatable m68k ELF object.
    const obj = b.addObject(.{
        .name = "HELLO",
        .root_module = hello,
    });
    obj.entry = .{ .symbol_name = "_start" };
    obj.bundle_compiler_rt = false;

    // Trampoline: guarantees code at text offset 0 (the PRG entry point).
    // Must be GNU `m68k-elf-as`: zig's bundled LLVM m68k assembler emits
    // `bra.l` (0x60FF = 32-bit displacement, 68020+ only) for an external
    // branch and has no `bra.w` form, which would break on a 68000.
    const startup = b.addSystemCommand(&.{ "m68k-elf-as", "-o" });
    const startup_o = startup.addOutputFileArg("startup.o");
    startup.addFileArg(b.path("src/startup.s"));

    // Stage 2: link object + trampoline -> relocatable ELF.
    const elf = b.addSystemCommand(&.{ "m68k-elf-ld", "--relocatable", "--gc-sections", "--script" });
    elf.addFileArg(b.path("prg.ld"));
    elf.addArg("-o");
    const elf_out = elf.addOutputFileArg("HELLO.elf");
    elf.addFileArg(startup_o);
    elf.addFileArg(obj.getEmittedBin());
    elf.step.dependOn(&startup.step);

    // Stage 3: ELF -> GEMDOS .PRG via toslink (output lands in the build cache).
    const toslink = b.addSystemCommand(&.{ "sh", "-c" });
    toslink.addArg("$HOME/Atari/bin/toslink -s -o \"$1\" \"$0\"");
    toslink.addFileArg(elf_out);
    const prg = toslink.addOutputFileArg("HELLO.PRG");
    toslink.step.dependOn(&elf.step);

    // Install the .PRG to ./zig-out/atari/HELLO.PRG.
    const install_prg = b.addInstallFileWithDir(prg, .{ .custom = "atari" }, "HELLO.PRG");
    b.getInstallStep().dependOn(&install_prg.step);
}
