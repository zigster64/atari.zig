const std = @import("std");

// GEMZ build: produces two Atari ST .PRG programs in ./zig-out/atari/:
//
//   HELLO.PRG  — src/welcome.zig  (classic form_alert welcome dialog)
//   WINDOW.PRG — src/window.zig   (minimal window + white box)
//
// Both import the "gemz" module (src/gemz.zig) as their GEM wrapper library,
// and both are copied into ~/Atari/CDrive/GEMZ/ for Hatari.
//
// `compileObject` compiles one app to a relocatable m68k object; `linkToPrg`
// turns that object into an Atari ST .PRG (startup trampoline → ld → toslink)
// and installs it. Add a new program by compiling one more module and calling
// `linkToPrg` — the linking pipeline is shared.

pub fn build(b: *std.Build) void {
    const gemz = b.addModule("gemz", .{
        .root_source_file = b.path("src/gemz.zig"),
    });

    const screen = b.addModule("screen", .{
        .root_source_file = b.path("src/screen.zig"),
        .imports = &.{
            .{ .name = "gemz", .module = gemz },
        },
    });

    const space_sprites = b.addModule("space_sprites", .{
        .root_source_file = b.path("src/space_sprites.zig"),
        .imports = &.{
            .{ .name = "gemz", .module = gemz },
        },
    });

    const target = b.resolveTargetQuery(.{
        .cpu_arch = .m68k,
        .os_tag = .freestanding,
        .abi = .none,
    });

    const welcome = b.createModule(.{
        .root_source_file = b.path("src/welcome.zig"),
        .target = target,
        .optimize = .ReleaseSmall,
        .imports = &.{
            .{ .name = "gemz", .module = gemz },
        },
    });

    const window = b.createModule(.{
        .root_source_file = b.path("src/window.zig"),
        .target = target,
        .optimize = .ReleaseSmall,
        .imports = &.{
            .{ .name = "gemz", .module = gemz },
        },
    });

    const daf = b.createModule(.{
        .root_source_file = b.path("src/daf.zig"),
        .target = target,
        .optimize = .ReleaseSmall,
        .imports = &.{
            .{ .name = "gemz", .module = gemz },
        },
    });

    const timer = b.createModule(.{
        .root_source_file = b.path("src/timer_test.zig"),
        .target = target,
        .optimize = .ReleaseSmall,
    });

    const counter = b.createModule(.{
        .root_source_file = b.path("src/counter.zig"),
        .target = target,
        .optimize = .ReleaseSmall,
        .imports = &.{
            .{ .name = "gemz", .module = gemz },
        },
    });

    const todo = b.createModule(.{
        .root_source_file = b.path("src/todo.zig"),
        .target = target,
        .optimize = .ReleaseSmall,
        .imports = &.{
            .{ .name = "gemz", .module = gemz },
        },
    });

    const space = b.createModule(.{
        .root_source_file = b.path("src/space.zig"),
        .target = target,
        .optimize = .ReleaseSmall,
        .imports = &.{
            .{ .name = "gemz", .module = gemz },
            .{ .name = "screen", .module = screen },
            .{ .name = "space_sprites", .module = space_sprites },
        },
    });

    const gfx2 = b.createModule(.{
        .root_source_file = b.path("src/gfx2.zig"),
        .target = target,
        .optimize = .ReleaseSmall,
        .imports = &.{
            .{ .name = "gemz", .module = gemz },
            .{ .name = "screen", .module = screen },
        },
    });

    const gfx_demo = b.createModule(.{
        .root_source_file = b.path("src/gfx_demo.zig"),
        .target = target,
        .optimize = .ReleaseSmall,
        .imports = &.{
            .{ .name = "gemz", .module = gemz },
            .{ .name = "screen", .module = screen },
            .{ .name = "space_sprites", .module = space_sprites },
        },
    });

    // GFX-COLOR: Low + Med Res (colour monitor). GFX-MONO: Hi Res mono
    // (mono monitor) — rez 2 needs a mono monitor, hence the split
    // (M68K_NOTES #17). Shared phase logic lives in gfx_demo.zig.
    const gfx_color = b.createModule(.{
        .root_source_file = b.path("src/gfx_color.zig"),
        .target = target,
        .optimize = .ReleaseSmall,
        .imports = &.{
            .{ .name = "gemz", .module = gemz },
            .{ .name = "screen", .module = screen },
            .{ .name = "gfx_demo", .module = gfx_demo },
            .{ .name = "space_sprites", .module = space_sprites },
        },
    });

    const gfx_mono = b.createModule(.{
        .root_source_file = b.path("src/gfx_mono.zig"),
        .target = target,
        .optimize = .ReleaseSmall,
        .imports = &.{
            .{ .name = "gemz", .module = gemz },
            .{ .name = "screen", .module = screen },
            .{ .name = "gfx_demo", .module = gfx_demo },
        },
    });

    linkToPrg(b, "HELLO", compileObject(b, "HELLO", welcome));
    linkToPrg(b, "WINDOW", compileObject(b, "WINDOW", window));
    linkToPrg(b, "DAF", compileObject(b, "DAF", daf));
    linkToPrg(b, "TIMER", compileObject(b, "TIMER", timer));
    linkToPrg(b, "COUNTER", compileObject(b, "COUNTER", counter));
    linkToPrg(b, "TODO", compileObject(b, "TODO", todo));
    linkToPrg(b, "SPACE", compileObject(b, "SPACE", space));
    linkToPrg(b, "GFX2", compileObject(b, "GFX2", gfx2));
    linkToPrg(b, "GFX-COLOR", compileObject(b, "GFX-COLOR", gfx_color));
    linkToPrg(b, "GFX-MONO", compileObject(b, "GFX-MONO", gfx_mono));
}

/// Compile a module to a relocatable m68k ELF object with `_start` as the
/// entry symbol (no compiler-rt — this is freestanding).
fn compileObject(b: *std.Build, comptime name: []const u8, mod: *std.Build.Module) *std.Build.Step.Compile {
    const obj = b.addObject(.{
        .name = name,
        .root_module = mod,
    });
    obj.entry = .{ .symbol_name = "_start" };
    obj.bundle_compiler_rt = false;
    return obj;
}

/// Link a compiled m68k object into an Atari ST .PRG and install it.
///
/// Pipeline: startup trampoline (GNU `m68k-elf-as`) → relocatable link
/// (`m68k-elf-ld` + prg.ld) → `toslink` .PRG → install to ./zig-out/atari and
/// copy to ~/Atari/CDrive/GEMZ.
fn linkToPrg(b: *std.Build, comptime name: []const u8, obj: *std.Build.Step.Compile) void {
    // Trampoline: guarantees code at text offset 0 (the PRG entry point).
    // Must be GNU `m68k-elf-as`: zig's bundled LLVM m68k assembler emits
    // `bra.l` (0x60FF = 32-bit displacement, 68020+ only) for an external
    // branch and has no `bra.w` form, which would break on a 68000.
    const startup = b.addSystemCommand(&.{ "m68k-elf-as", "-o" });
    const startup_o = startup.addOutputFileArg("startup.o");
    startup.addFileArg(b.path("src/startup.s"));

    // Link object + trampoline -> relocatable ELF.
    // `--gc-sections` is intentionally NOT used here: with `--relocatable` it
    // can non-deterministically drop the app's .rodata (object trees, TEDINFO),
    // which made G_TEXT objects vanish while G_BUTTON strings survived.
    const elf = b.addSystemCommand(&.{ "m68k-elf-ld", "--relocatable", "--script" });
    elf.addFileArg(b.path("prg.ld"));
    elf.addArg("-o");
    const elf_out = elf.addOutputFileArg(name ++ ".elf");
    elf.addFileArg(startup_o);
    elf.addFileArg(obj.getEmittedBin());
    elf.step.dependOn(&startup.step);

    // ELF -> GEMDOS .PRG via toslink.
    const toslink = b.addSystemCommand(&.{ "sh", "-c" });
    toslink.addArg("$HOME/Atari/bin/toslink -s -o \"$1\" \"$0\"");
    toslink.addFileArg(elf_out);
    const prg = toslink.addOutputFileArg(name ++ ".PRG");
    toslink.step.dependOn(&elf.step);

    // Install to ./zig-out/atari/<name>.PRG.
    const install_prg = b.addInstallFileWithDir(prg, .{ .custom = "atari" }, name ++ ".PRG");
    b.getInstallStep().dependOn(&install_prg.step);

    // Copy into the Hatari C: drive for testing.
    const install_cd = b.addSystemCommand(&.{ "sh", "-c" });
    install_cd.addArg("mkdir -p ~/Atari/CDrive/GEMZ && cp \"$0\" ~/Atari/CDrive/GEMZ/" ++ name ++ ".PRG");
    install_cd.addFileArg(prg);
    b.getInstallStep().dependOn(&install_cd.step);
}
