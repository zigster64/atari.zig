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

    // ── 1. Compile to object (.o) — LLD has no m68k backend ───────────────

    const obj = b.addObject(.{
        .name = "HELLO",
        .root_module = mod,
    });
    obj.entry = .{ .symbol_name = "_start" };
    obj.bundle_compiler_rt = false;

    // ── 2. Link + binary extract + GEMDOS header → HELLO.PRG ──────────────

    const prg = b.addSystemCommand(&.{ "sh", "-c" });
    prg.addArg(
        \\set -e
        \\mkdir -p ~/Atari/CDrive
        \\DIR="$(mktemp -d)"
        \\m68k-elf-ld --gc-sections --script "$1" -o "$DIR/hello.elf" "$0"
        \\
        \\TEXT_SZ=$(m68k-elf-size -A "$DIR/hello.elf" | awk '/^\.text/{print $2}')
        \\DATA_SZ=$(m68k-elf-size -A "$DIR/hello.elf" | awk '/^\.data/{print $2}')
        \\BSS_SZ=$(m68k-elf-size -A "$DIR/hello.elf"  | awk '/^\.bss/{print $2}')
        \\START_VMA=$(m68k-elf-nm "$DIR/hello.elf" | awk '$3=="_start"{print $1}')
        \\DISP=$((16#$START_VMA + 0x1c - 2))
        \\
        \\python3 -c "
        \\import struct, sys
        \\disp = $DISP
        \\hdr = struct.pack('>2s6Ih',
        \\    b'\\x60' + bytes([disp]),      # BRA.S to _start
        \\    $TEXT_SZ, $DATA_SZ, $BSS_SZ,   # segment sizes
        \\    0, 0, 0, 0,                    # sym, reserved, flags, absflag
        \\)
        \\assert len(hdr) == 28
        \\sys.stdout.buffer.write(hdr)
        \\" > "$DIR/header.bin"
        \\
        \\m68k-elf-objcopy -O binary "$DIR/hello.elf" "$DIR/hello.bin"
        \\cat "$DIR/header.bin" "$DIR/hello.bin" > ~/Atari/CDrive/HELLO.PRG
        \\rm -rf "$DIR"
    );
    prg.addFileArg(obj.getEmittedBin());    // $0
    prg.addFileArg(b.path("prg.ld"));        // $1

    b.getInstallStep().dependOn(&prg.step);
}
